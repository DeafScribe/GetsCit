# CLAUDE.md — Citadel 2025

Read this before proposing anything. It exists so settled decisions don't
get re-litigated every session.

## What this is

A browser-based reimplementation of **Citadel-86 v3.49**, a DOS-era BBS.
Scoped deliberately: user interaction with the room and message database.
**Out of scope from the start:** inter-BBS networking (C86Net), sysop
operator-console features, doors, file transfer protocols.

The guiding filter for every decision: *does this preserve what made 3.49
simple and pleasant to use, or is it cruft that only existed because of
1985 hardware constraints?* Bit-packed records, circular message files,
and three-bit read pointers were correct answers to problems that no
longer exist. The interaction model — rooms, sequential unread traversal,
single-key commands — is the thing worth keeping.

## Current state

Design is far ahead of implementation. **The application does not exist
yet** — there is no server, no routes, no `bun` entry point. What exists
is a verified schema, a set of standalone logic modules written against
it, two frontend mockups, and ops scripts. None of it has ever run
together.

Next work is the server itself: request pipeline, `Host`-header instance
lookup, session middleware, and wiring the existing modules into routes.

## Stack (locked)

- **Bun** — chosen over Node for built-in `bun:sqlite` (no native addon)
  and `Bun.password` (native argon2id, no native addon). Smaller resident
  memory on a small VM.
- **SQLite**, WAL mode, **one file per instance**. Sole datastore.
- **Caddy** — reverse proxy, automatic Let's Encrypt, one site block per
  subdomain. Explicitly chosen over nginx.
- **Plain HTTP** for all core messaging. Async post-and-refresh polling.
- **SSE** for aide-chat only. This is a deliberate narrow exception, not
  a general pattern.

## Decisions that will get re-suggested — don't

Each of these was considered and rejected for a specific reason. If you
find yourself about to propose one, the answer is already no.

| Suggestion | Why it's rejected |
|---|---|
| WebSockets for messaging | Async delivery was chosen on purpose. Real-time requires a connection registry and presence for all users; the BBS model doesn't need it. |
| Rich text editor (Lexical/Tiptap/Quill) | Tier 0 — plain `<textarea>`. Deliberate. |
| Markdown rendering of messages | Would reintroduce the XSS surface that `textContent`-only closes. |
| Redis / message queue / separate cache | Solves problems that don't exist at 250 users on one VM. |
| P2P, WebRTC, ATProto, BitTorrent | All evaluated at length. Browsers can't accept inbound connections; swarm health fails at this community size. |
| Content-hash message IDs / CRDT merge | Made sense for the abandoned P2P design. With one server there's a single source of truth — autoincrement integers are correct. |
| Litestream | Considered; the baseline+delta+rclone design was chosen instead. |
| Snyk / SIEM / ELK | Over-scaled. `fail2ban` + a daily digest script is the right tier. |
| Cookie consent banner | The only cookie is strictly-necessary session auth. Nothing to consent to. |
| Google Fonts CDN | Real GDPR problem — visitor IP leaves to a third party before consent is possible. Font is self-hosted; CSP is `'self'` everywhere. |
| Email / SMTP for anything | No mail infrastructure. Password recovery is aide-mediated by design. |
| Telnet access | Browsers cannot open raw TCP sockets. Would be a second front-end. |

## Invariants — breaking these breaks the system silently

**`textContent`, never `innerHTML`.** Every render path for user-authored
text: messages, usernames, room names, bios, error messages that echo
input. There is no sanitizer library; the discipline *is* the defense. A
CSP of `script-src 'self'` backstops it, which is also why there are no
inline `<script>` or `<style>` blocks anywhere.

**Mail privacy lives in a `WHERE` clause, not in the data.** Any query
touching `messages` must account for the Mail room. `find.js` already
does. A naive `SELECT ... WHERE body LIKE ?` would return every user's
private mail to anyone searching a common word — silently, with no error,
looking like a working feature. Rule: mail is **recipient-only** — the
sender cannot see their own sent mail. There is no sent folder.

**Rate-limit anything that verifies a password.** `/login`, `/setup`, and
`/password` all do. The last is easy to miss because the user is already
authenticated — but a hijacked session could otherwise brute-force the
existing password at full speed. Check the limit *before* the hash
comparison and skip the comparison when throttled; argon2id is
deliberately slow.

**The `Host` header selects the database — whitelist it, never sanitize
it.** Match against `.db` files actually present in the data directory, or
an explicit allowlist. Anything unmatched is a 404 with no filesystem
call. A `Host` of `../../etc/passwd` must never reach a `path.join`. Don't
inherit safety from Caddy's routing; the app may be reached directly on
localhost.

**Gates are single choke points, mounted first — never per-route checks.**
`setup-gate-middleware.js` is the pattern. A check duplicated per route is
one someone forgets to add to the next route. Note the setup gate is
*symmetric*: before setup, everything except `/setup` is blocked; after
setup, `/setup` itself 404s permanently. The second direction matters more
— a live account-creation endpoint is a standing vulnerability.

**The same shape is still needed for `must_reset_password`.** Whatever
middleware enforces it must allow `POST /password` through, or the user is
locked out of the only route that could unlock them. **Not yet written.**

**An unlisted table is silently never backed up.** `backup.sh` has
explicit `APPEND_TABLES` and `MUTABLE_TABLES` arrays. Adding a table to
the schema without adding it there produces no error. This already
happened: `floors` went two days unbacked-up. Three tables are excluded
*on purpose* — `sessions` (restoring a token resurrects a live
credential), `aide_status` (resets to all-offline on boot; restoring it
restores a lie), `login_attempts` (ephemeral).

**Soft-delete, never hard `DELETE`.** A deleted row leaves no watermark
trace, so a restore from baseline+deltas silently resurrects it.
`rooms.deleted_at` and `floors.deleted_at` exist for this. Any future
delete feature needs the same.

## Commands

Main menu: `C E F G H I K M S T U Z ?`

**Cut:** `D`oors (out of scope). `L`ogin (dial-up artifact — login is a
page, not a command). `F`orward/`N`ew/`O`ld/`R`everse read — four commands
that all meant "show messages from here, in this direction," which existed
because a 1986 terminal couldn't scroll. `G`oto now enters a room *and*
auto-displays new messages, absorbing `N`.

**Kept against first instinct:** `T`erminate. Closing a tab isn't logging
out; logout-but-stay-put matters on a shared machine. It deletes the
session row.

**New:** `F`ind, replacing the original's `<U>ser` and `<P>hrase`. Those
were *modifiers* on a read verb (`.Read User Forward`), and that grammar
left with F/N/O/R — but scrolling replaces navigation, not search, so they
were promoted to a top-level command. Find mode: `U` by user, `P` by
phrase, `G` toggles room/global scope. Prompt shows state:
`Find [room]>` / `Find [global]>`.

**Modal contexts are retained** — the same letter means different things
in different modes (`S` = Skip room / Status / Shared rooms). This is
deliberate, and it has a cost: the hotkey handler needs mode state, not a
flat lookup table. A plain `keydown` listener is still the right scale;
`tinykeys` only if bindings grow. **Not implemented.**

**Exit convention, every modal:** Enter *or* Backspace on an empty prompt
backs out one level. Two presses from a term prompt reaches main.
Backspace-on-empty needs an explicit
`e.key === 'Backspace' && input.value === ''` check — there's no native
event. Any keydown handler also needs a guard so it doesn't hijack typing
in a textarea.

## Other locked decisions

- **Sessions:** server-side table + `httpOnly; Secure; SameSite=Lax`
  cookie. `Lax` not `Strict`, so shared links into the BBS don't render as
  logged-out on first click.
- **Password recovery:** aide-mediated, temp password expires in one hour
  (`users.temp_password_expires_at`), reset posts into the Aide room.
- **`read_state.last_read_message_id` advances on room EXIT, not on
  display.** That's what makes `S`kip meaningful — marking at display time
  would leave nothing to skip.
- **Presence is one boolean per aide** (`aide_status`), never generalized
  to ordinary users. All aides reset to offline on startup.
- **Aide chat:** user↔aide only. `C <name>` targets by name; bare `C`
  defaults to the sysop. **Strict fail, no fallback** if unavailable. One
  active session per aide.
- **Instance files:** `[system].[domain].db`, e.g.
  `two.castletalk.com.db`, sharing a stem with the Caddy log
  (`two.castletalk.com.log`) so scripts derive one from the other. The
  display name in `site_config` is decoupled — it's sysop-editable and
  must never become a path.
- **Preset rooms:** `Lobby`, `Mail`, `Aide` seeded in `schema.sql`. `Aide`
  is load-bearing — `audit.js` and `security-digest.sh` both query
  `WHERE name = 'Aide'`.
- **Floors:** schema exists, feature dormant and undocumented to users.
- **Audit logging is two-tier:** everything to `audit_log` (silent,
  queryable); a short `NOTABLE_ACTIONS` list *also* posts into the Aide
  room. Keep that list short — if everything posts there, nobody reads it.

## Known gaps

- No server, no routes, no entry point.
- `must_reset_password` middleware (see above).
- No moderation route for `users.bio` — first user-authored text shown
  outside a room, and no aide can clear an abusive one.
- Nothing writes `rooms.description` or `users.bio` yet, though `I` and
  `M` depend on them.
- No restore script. `backup.sh` writes; nothing reads back. Deferred
  deliberately, but it's untested-by-definition until it exists.
- `Bun.password.hash` / `.verify` in `password.js` are **unexecuted** —
  written against the documented API but never run, because the design
  sandbox had no Bun. Verify these first.
- Dot commands (`.` prefix) survive as a menu entry but their contents are
  unreviewed. `;` floor commands likewise, dormant with floors.
- Mobile interface — deferred entirely. A bottom mode-aware button bar was
  sketched but not built; note that touch buttons and modal contexts
  interact awkwardly (buttons must repaint per mode).

## Verification standard

Schema and logic in this repo were tested by execution, not by
inspection — triggers actually firing, constraints actually rejecting,
the mail filter actually hiding rows from an uninvolved user. Hold new
work to the same bar. "It looks right" has already been wrong once here.

## Reference material

`reference/` holds primary sources, not background reading:

- **`HACK3.MAN`** — the original internal architecture doc (Cynbe ru
  Taren, 1982; updated 1985). Explains *why* the original is shaped as it
  is. Note `ctdlLog.sys` is the **user account database**, not an event
  log — "log record" in 1980s Citadel vocabulary means account record.
- **`OPER3.MAN`** — Operations Manual v3.32. Sysop-facing. Section V
  (room attributes) has a fuller flag list than currently implemented.
  Networking sections are cleanly separable and out of scope.
- **`citadel-help-files-curated.zip`** — 65 surviving `.hlp`/`.mnu`/`.blb`
  files from v3.49, after cutting transfer-protocol, networking,
  flow-control, and doors content. Full relevance triage still pending.
- Original source: `stevesteffler/citadel-86` on GitHub.
