# Citadel 2025 — Project Roadmap
*Compiled from project discussion to date. Reflects the browser-based reimplementation of Citadel-86 v3.49, scoped to user interaction with the room/message system — networking between BBS instances and sysop-operator-console features excluded from the start.*

---

## 1. Resolved Design Decisions

### Architecture
- **Single lightweight VM**, single application process. No message queue, no Redis, no separate cache layer — deliberately rejected as solving problems this scale doesn't have.
- **SQLite** as the only datastore. WAL mode for crash safety.
- **HTTP-only transport** for the core app — no WebSocket. Async **post-and-refresh** model: client `POST`s a message, polls `GET .../messages?since=<id>` for what's new. Chosen over real-time push specifically to avoid building a connection registry/presence system for the whole user base.
- **Server-Sent Events (SSE)**, scoped *only* to the aide-chat feature — the one place genuine real-time delivery is needed. Two open connections per active session, not a system-wide registry.
- **Bun** as the runtime — chosen over Node primarily for the built-in `bun:sqlite` driver (no native-addon dependency) and `Bun.password` (native argon2id/bcrypt, no native-addon dependency either). Smaller baseline memory footprint fits the "small VM" constraint.
- **Caddy** as reverse proxy/TLS terminator — automatic Let's Encrypt certs, per-subdomain config blocks. Formally confirmed as the choice (was used by default throughout before being put on the record).
- **Multiple BBS instances via subdomains** (`two.castletalk.com`, not `castletalk.com/two`) — cookie isolation falls out of the browser's same-origin rules automatically, rather than requiring careful `Path`-scoped cookies.
- **Per-subdomain Caddy certs**, not a wildcard — lower ongoing maintenance for a small, operator-added set of instances; no DNS-provider API credentials to store.
- **One SQLite file per instance**, selected by the `Host` header at the top of the request path. **Naming convention: `[system].[domain].db`** — e.g. `two.castletalk.com.db`, matching the Caddy access log's `two.castletalk.com.log`. Sharing the stem is what lets `backup.sh`, `cleanup.sh`, and `security-digest.sh` derive one path from the other with a single `basename` call; verified that this survives the multi-dot hostname correctly.
- **Consolidated `schema.sql`** — thirteen tables: `users`, `rooms`, `floors`, `messages`, `content_pages`, `site_config`, `chat_sessions`, `chat_messages`, `sessions`, `read_state`, `aide_status`, `login_attempts`, `audit_log`. Verified by actually applying it and testing behaviour (triggers fire, composite keys reject duplicates, at-most-one-sysop holds, session purge works) rather than only written. Folds in the four prior patch files rather than layering migrations, since nothing was live. `updated_at` triggers cover every mutable table.
  - **`read_state(user_id, room_id, last_read_message_id, forgotten_at)`** — backs `G`, `S`, `K`, `Z`. `last_read_message_id` advances **on room exit, not on display** — that's what makes `S`kip meaningful; marking at display time would leave nothing to skip. `forgotten_at` lives here rather than its own table because it's the same grain.
  - **`sessions(token, user_id, created_at, expires_at)`** — the auth model had no table behind it until now; `T`erminate deletes the row.
  - **`aide_status(aide_id, is_available)`** — the entire presence system, one boolean per aide, never generalised to ordinary users.
  - **`users.temp_password_expires_at`** — `must_reset_password` was a bare flag with nothing to expire against, so the one-hour aide-reset window wasn't actually enforceable.

### Data & Backup
- **Backup model:** monthly full baseline (`VACUUM INTO`) + daily incremental deltas. Append-only tables (`messages`, `chat_messages`, `audit_log`) diffed by `id`; mutable tables (`users`, `rooms`, `content_pages`, `site_config`, `chat_sessions`) diffed by `updated_at` and replayed with `REPLACE INTO` (upsert).
- **`login_attempts`, `sessions`, and `aide_status` are all deliberately excluded** from backup, each for its own reason: rate-limiting arithmetic is ephemeral; a restored session token would resurrect a live credential; restored availability flags would be restoring a lie (they reset to all-offline on boot anyway). Documented in `backup.sh` rather than left implicit. **Failure mode worth knowing: an unlisted table produces no error, it simply never gets backed up** — `floors` was in that state for two days before being caught.
- **Off-site shipping via `rclone`** (`copy`, never `sync`) to a to-be-chosen object storage provider. Restic considered and passed over — this script's own baseline+delta output already provides the versioning restic would add.
- **Soft deletes**, not hard `DELETE`, for `rooms` (`deleted_at`) — keeps the mutable-table backup logic correct without special-casing.
- **Known, accepted gap:** deletions of rows without a soft-delete column aren't captured by the incremental model; not currently an issue since nothing hard-deletes yet.

### Auth & Security
- **Password hashing:** `Bun.password` (argon2id, OWASP 2026 baseline params: m=19MiB, t=2, p=1; tune toward 250–500ms verification time).
- **Sessions:** server-side session table + `httpOnly; Secure; SameSite=Lax` cookie. `Lax` chosen over `Strict` specifically to avoid breaking shared links into the BBS from outside.
- **Password recovery:** aide-mediated only, no email/SMTP anywhere in the system. Temp password expires in 1 hour; every reset logged via a post into the Aide room.
- **First-run setup:** a single hard-gated `/setup` route (see file list) bootstraps site config *and* the first aide account together; gate is a single middleware choke point, not a per-route check; `/setup` becomes permanently unreachable once `setup_complete` flips true, and only flips true after the aide account write actually commits.
- **Rate limiting:** per-username escalating delay (5th failure → 1s, doubling, capped at 30s; resets on success or 15 min quiet) *and* independently per-IP hard threshold (20 failures/10 min → 20 min cooldown). Applied to both `/login` and `/setup` (the latter reasoned as "first login" using an out-of-band-supplied password).
- **XSS:** closed by discipline, not a library — `textContent` only, never `innerHTML`, for any user-authored text, enforced as a rule rather than a sanitizer dependency.
- **CSRF:** closed by `SameSite=Lax` alone — no separate CSRF token needed since every mutation is already a `POST`.
- **CSP:** fully `'self'` on every directive after the font was self-hosted — no external trust required anywhere.
- **GDPR/cookies:** no consent banner needed (the one cookie is strictly-necessary session auth) — but the Google Fonts CDN call was a real, separate GDPR issue (IP sent to a third party pre-consent), fixed by self-hosting the font.
- **fail2ban** on SSH — closes the port-22 brute-force risk flagged at the very start of the project.
- **Audit trail, two-tier:** `audit_log` (structured, queryable, silent) for everything; a short, deliberately non-exhaustive list of *notable* actions (room deletion, permission grants, aide creation, password resets) also post into the Aide room, reusing the existing message system as the human-readable layer.
- **Intrusion detection, "simple" tier:** `fail2ban` (host-level) + a daily `security-digest.sh` reading `login_attempts`/`audit_log`/Caddy's access log, posting a rollup into the Aide room. Explicitly not a SIEM/ELK stack — right-sized for one VM.
- **Aide availability on restart/crash:** all aides default to offline; nothing carries forward a possibly-stale "available" flag.

### Permissions
- **Roles:** `users.role` (`user`/`aide`) plus `is_sysop` (enforced to at most one per instance via a partial unique index) plus `can_delete_rooms` (a per-aide toggle only the sysop may set).
- **Room deletion:** sysop-only by default; sysop can grant `can_delete_rooms` to specific aides. No self-granting.

### Commands (main menu)

Reviewed against the original `mainopt.mnu`. **Surviving:** `C`hat, `E`nter message, `F`ind, `G`oto, `H`elp, `I`nformation on current room, `K`nown rooms, `M`eet user, `S`kip room, `T`erminate, `U`ngoto, `Z`Forget room, `?` menu.

**Cut, with reasons:**
- `D`oors — feature out of scope entirely.
- `L`ogin — artifact of the dial-up model (connect anonymously, then identify). Session cookies handle this; login is a page, not a command.
- `F`orward / `N`ew / `O`ld / `R`everse read — four commands that all meant "show messages from here, in this direction." They existed because a 1986 terminal couldn't scroll. A browser pane scrolls natively, so three of them were scroll gestures wearing command clothing. `G`oto now enters a room *and* auto-displays new messages, absorbing what `N` did.

**Kept against initial instinct:** `T`erminate. Closing a tab isn't the same as logging out — logout-but-stay-put matters on a shared machine. `T` deletes the session row.

**New:** `F`ind, replacing the original's `<U>ser` and `<P>hrase`, which were *modifiers* on a read verb (`.Read User Forward`) rather than standalone commands. That grammar left with F/N/O/R; the search functions it hosted did not become obsolete (scrolling replaces navigation, not search), so they were promoted to a top-level command.

- **Find mode:** `U` (by user), `P` (by phrase), `G` toggles scope. Defaults to current room; prompt shows state (`Find [room]>` / `Find [global]>`).
- **Modal contexts retained** — the same letter means different things in different modes (`S` = Skip room / Status / Shared rooms), as in the original. This has a real implementation cost: the hotkey handler needs mode state, not a flat lookup table.
- **Exit convention, applies to every modal:** Enter or Backspace on an empty prompt backs out one level. Two presses from a term prompt reaches the main prompt. Backspace-on-empty needs an explicit `e.key === 'Backspace' && input.value === ''` check — there's no native event for it.
- **Discoverability** relies on users working it out, with `?` available as the safety net if made modal-aware (showing the *current* mode's options, as the original did with per-context `.mnu` files).

### Features
- **Aide chat:** user↔aide only (not general user↔user). `C <name>` targets a specific aide by name; bare `C` defaults to the sysop specifically (not "first available aide"). **Strict fail, no fallback** if the named target (or the sysop, by default) is unavailable — same message either way. One active session per aide at a time.
- **Search (`F`ind):** built as `find.js`. Two modes (user, phrase), current-room default with a global toggle, results capped at 100 newest-first. **The Mail room is filtered in every query** — mail privacy lives in a `WHERE` clause, not in the data, so a naive search would have returned everyone's private mail to anyone searching a common word, silently and with no error. Verified: an uninvolved user sees only public results, a recipient sees their own mail, and a *sender* sees neither their own sent mail nor anyone else's — search is not a back door around the recipient-only rule. Phrase search uses `LIKE` (full scan); FTS5 is the upgrade path if it ever stops being fast enough.
- **Message entry:** Tier 0 — a plain `<textarea>`, no rich-text editor, no markdown renderer. Matches the project's minimalism throughout.
- **Baud-rate text streaming:** approved as a future *client-side-only* rendering effect (text already fully delivered; only the reveal is throttled). Default **off** until built; target default rate **1200 baud**, held pending real testing across classic rates. Skip-to-complete via any keypress or tap/click — deliberately *not* bound to the `S` key, since `S` already means "Skip room" in the original and reusing it would collide with a real feature.
- **Global hotkeys:** a plain `keydown` listener remains the right scale (no library needed), but the confirmed decision to keep modal contexts rules out the simplest flat `switch` — dispatch must go through current-mode state. `tinykeys` remains the fallback if the binding set ever grows past this. **Not yet implemented.**
- **Doors:** removed entirely, help file and concept both — confirmed never built in this project, nothing to remove beyond the help text.

### Content
- **Help/menu files:** uploaded archive (83 files nominal, 82 real after macOS junk) triaged down to **65 remaining**, after removing:
  - Transfer-protocol blobs (`wxdown.blb`, `wxup.blb`, `ymdown.blb`, `ymodemup.blb`, `ymupload.blb`, `wcdown.blb`, `wcupload.blb`)
  - Networking-era files (`net-mail.hlp`, `netopt.mnu`, `netrooms.hlp`, `netrooms.mnu`, `netedit.mnu`, `domains.hlp`)
  - Protocol/flow-control help (`protocol.hlp`, `flow.hlp`, `novflow.hlp`)
  - Doors help (`doors.hlp`)
- **`content_pages` design:** key/label/body/updated_at/updated_by, admin form with a dropdown to select which page to edit — **designed in conversation, not yet built as an artifact.**
- **Floors:** decision made to **implement the underlying functionality**, but keep it undocumented/unintroduced to users for now. Schema now exists (`floors` table, `rooms.floor_id`, nullable) — activation design (whether every room must belong to a floor, or grouping is optional) still to be done.
- **Preset rooms:** every fresh instance seeds `Lobby`, `Mail`, and `Aide` directly in `schema.sql`. `Aide` was seeded specifically because `audit.js`/`security-digest.sh` already assumed it exists — a latent gap closed in passing.
- **Internal mail:** `messages.recipient_id` (nullable, only meaningful for posts to the `Mail` room) — follows the original's own model (reuse the message mechanism, one extra field) rather than a separate mailbox system. Reading Mail is **recipient-only** — confirmed decision, verified working: a sender cannot see their own sent mail after sending it, no "sent" folder equivalent. No cross-instance/networked mail, matching this project's scope everywhere else.

### Reference documents reviewed
- `hack.doc` — original internal architecture manual (1982/1985). Confirmed: no dedicated security/audit log in the original (`ctdlLog.sys` is the *user account* database, not an event log); circular message file; bit-packed per-user state; plaintext password storage historically.
- `OPER3.MAN` — Operations Manual v3.32. Table of contents reviewed and mapped against current decisions; full section-by-section read not yet done, available on request.

---

## 2. Missing / Not Yet Built

These are gaps with no decision pending — just not yet done:

- **No actual application route code** beyond illustrative snippets in comments (`/login`, `/setup` handler bodies, room/message CRUD, chat request/session endpoints, content-page admin routes).
- **No restore script** — `backup.sh` writes backups; nothing reads them back. Deliberately deferred (see §3), but worth listing here since it's a genuine capability gap in the meantime.
- **No permission-check middleware** for "only `is_sysop` may modify another user's `can_delete_rooms`" — noted in the schema comments as needing to live in application code, not yet written.
- **No real UI beyond two artifacts**: the CRT interface mockup (room/message shell) and the `/setup` wizard. No login page, no room-list navigation, no chat UI, no admin panels for `content_pages`/`site_config`/room management have been built.
- **No moderation route for user bios.** `users.bio` is the first user-authored text in the system displayed to *other* users outside a room, and an aide has no way to clear an abusive one. The permission model has no granular toggle for it either (`can_delete_rooms` is the only one).
- **No room-description or bio editing routes** — the columns exist (`rooms.description`, `users.bio`), backing `I` and `M` respectively, but nothing writes to them yet.

## 3. Deferred (Consciously Postponed)

- **Dot commands (`.`)** — the original's extended-command syntax (`.Read User Forward`, `.Enter Room`, `.Help DOT`). Retained as a main-menu entry but its contents are entirely unreviewed; `dot.hlp` was kept in the triage for this purpose. Much of what it hosted (`.Enter Xmodem Message`, `.Enter Net-Message`) is already out of scope.
- **Full help/menu content triage** — the 65 remaining files still need real relevant/obsolete judgment, held until the system is further architected.
- **Restore script** — held until the system is more fully built, on the reasoning that the shape of what needs restoring will be clearer later.
- **File upload/download feature** — placed on the roadmap as a future item, not current scope. BitTorrent-based distribution specifically considered and set aside (swarm-health math doesn't work at this community size; added legal exposure for the operator) — if/when file transfer is built, plain server-stored uploads are the sane starting point.
- **Mobile interface adaptation** — explicitly flagged as its own future conversation, untouched so far.
- **Full read of `OPER3.MAN`** — TOC-level mapping done; section-by-section review available whenever wanted.

## 4. Suggested but Unconfirmed

Items where an option was presented and reasoned through, but no final commitment was made:

- **Global hotkey mechanism** — a plain `keydown` listener with mode state is the recommendation; `tinykeys` as fallback. No implementation committed either way yet.

---

## 5. File Inventory (prepared to date)

| File | Purpose |
|---|---|
| `citadel86-io-flowchart.mermaid` | Input/output flowchart of the *original* Citadel-86 command loop and room/message DB interaction (reference material, not this project's design) |
| `crt-interface.html` | CRT terminal-style mockup shell — room/message display, entry line, theme toggle markup |
| `crt-interface.css` | Green/amber phosphor styling, scanlines, restrained glow, self-hosted `@font-face` |
| `crt-interface.js` | Theme toggle logic, local message-append demo wiring (`textContent`-only) |
| `setup.html` | First-run setup form: site identity, access-policy toggles, first aide account creation |
| `setup.css` | Minimal functional styling for the setup form (shares the phosphor palette, not the full CRT effects) |
| `setup.js` | Client-side validation + `POST /setup` wiring for the setup form |
| `setup-gate-middleware.js` | Reference middleware — the single choke point gating every route on `setup_complete`, mounted first, before any other route |
| `schema.sql` | **Consolidated base schema** — all core tables, indexes, and updated_at triggers in one file. Supersedes the four rows below. |
| ~~`schema-rate-limiting.sql`~~ | *Superseded by `schema.sql`* — folded in |
| `rate-limiter.js` | Per-username escalating delay + per-IP threshold logic, shared by `/login` and `/setup` |
| `cleanup.sh` | Daily cron: prunes `login_attempts` past 5 days **and** expired `sessions` rows, across all instance `.db` files. *(Renamed from `cleanup-login-attempts.sh`, which no longer described what it does — update any cron entry written against the old name.)* |
| `backup.sh` | Baseline + incremental backup script; `rclone`-based off-site shipping; per-instance `flock`-guarded |
| ~~`schema-chat-sessions-updated-at.sql`~~ | *Superseded by `schema.sql`* — folded in |
| ~~`schema-room-deletion-permissions.sql`~~ | *Superseded by `schema.sql`* — folded in |
| ~~`schema-audit-log.sql`~~ | *Superseded by `schema.sql`* — folded in |
| `audit.js` | Two-tier logging: always writes `audit_log`; a short `NOTABLE_ACTIONS` list also posts into the Aide room |
| `mail.js` | Internal mail — post to the Mail room with a recipient, and the recipient-only read that makes it private |
| `find.js` | The `F`ind command — user and phrase search, room/global scope, with the Mail-room filter applied to every query |
| `Caddyfile-logging-snippet` | Per-instance Caddy config enabling persistent access-log files (rolled, retained ~30 days) |
| `fail2ban-jail.local` | SSH brute-force protection — standard package config, not custom code |
| `security-digest.sh` | Daily digest: reads `login_attempts` + `audit_log` + Caddy's access log, posts a summary into the Aide room |
| `citadel-help-files-curated.zip` | The 65 surviving `.hlp`/`.mnu`/`.blb` files after the transfer/network/protocol/flow/doors cuts |

---

## 6. External Applications & Services Required

**Core stack:**
- **Bun** — application runtime (includes `bun:sqlite` and `Bun.password` natively; no separate SQLite driver or password-hashing package needed).
- **SQLite** — embedded via Bun; the `sqlite3` CLI is also used directly by the shell scripts (`backup.sh`, `cleanup-login-attempts.sh`, `security-digest.sh`) and should be present on the VM independent of the app.
- **Caddy** — reverse proxy, automatic TLS via Let's Encrypt (implicit dependency, no separate install).

**Security/ops tooling:**
- **fail2ban** — SSH protection (`apt install fail2ban`).
- **rclone** — off-site backup shipping; needs `rclone config` run once with real provider credentials (not yet chosen — S3, R2, B2, etc. all viable).
- **jq** — used by `security-digest.sh` to parse Caddy's JSON access logs; needs to be present on the VM.
- **GitHub Dependabot** — needs enabling on the repository itself (a settings checkbox, no config file required for basic security-update PRs). *Action item, not yet done.*

**Infrastructure not yet chosen, purely operational:**
- A VPS/hosting provider.
- A domain registrar + DNS provider.
- An object-storage provider for `rclone`'s backup destination.

**Considered and explicitly rejected** (listed for completeness, so they don't get silently reconsidered later without the reasoning being visible):
- Node.js + `better-sqlite3` + `argon2` npm packages — viable fallback if Bun ever causes friction, but not the current choice.
- Redis, a message queue, WebSockets for core messaging — all rejected as solving problems this scale doesn't have.
- WebRTC/STUN/TURN, ATProto — rejected for peer-to-peer messaging; centralized server chosen instead.
- Litestream — considered for continuous WAL-based backup replication; the baseline+delta+`rclone` design was chosen instead.
- Snyk / SIEM / ELK-style log aggregation — rejected as over-engineering for a single-VM hobby-scale system; `fail2ban` + the daily digest script judged sufficient.
- BitTorrent/WebTorrent hooks for file management — rejected for this community size; plain server-stored uploads is the fallback if/when file management is actually built.
- A cookie-consent banner — unnecessary; the only cookie in the system is strictly-necessary session auth.

---

*This document reflects the state of the project as of this compilation. It should be treated as a living reference — re-generate or amend it as further decisions close out items in §2–§4.*
