# Citadel 2025

Browser-based reimplementation of Citadel-86 v3.49.

**Status: pre-implementation.** The schema and supporting modules exist
and are tested. The application server does not exist yet.

If you are Claude, read `CLAUDE.md` first.

## Layout

```
db/schema.sql          Complete schema, verified by execution
src/lib/               Standalone modules, not yet wired to routes
public/interface/      CRT terminal mockup (theme toggle works; posting is a local demo)
public/setup/          First-run setup form
public/assets/         Synthesized modem connect audio
ops/                   Backup, cleanup, digest, Caddy and fail2ban config
tools/                 Audio generators (regenerate/retune the .wav files)
docs/roadmap.md        Full decision record and gap list
docs/superseded/       Early schema patches, folded into db/schema.sql
reference/             Original manuals and curated v3.49 help files
```

## Before anything runs

1. **Verify `Bun.password`.** `src/lib/password.js` calls `.hash()` and
   `.verify()` but they were never executed — the design environment had
   no Bun. This is the first thing to test.
2. **Add `VT323.woff2`** to `public/interface/`. Download from
   fonts.google.com/specimen/VT323. Until it's there the CRT interface
   falls back to Courier New. The CDN version was removed deliberately
   (GDPR — see `CLAUDE.md`).
3. **`rclone config`** — `ops/backup.sh` expects a remote named
   `citadel-backup` and exits non-zero without it. No provider chosen yet.
4. **Enable Dependabot** on the repository.

## Standing up an instance

Four manual steps, by design (no wildcard cert, no self-service):

1. DNS A record: `two.castletalk.com` → VM IP
2. Caddy site block, then `caddy reload`
3. `sqlite3 two.castletalk.com.db < db/schema.sql`
4. Visit the subdomain — the setup gate serves `/setup`, where you set the
   display name and create the first aide account

## Cron

```
17 3 * * *  flock -n /tmp/citadel-cleanup.lock ops/cleanup.sh   >> /var/log/citadel-cleanup.log 2>&1
23 3 * * *  ops/backup.sh                                        >> /var/log/citadel-backup.log 2>&1
45 3 * * *  ops/security-digest.sh                               >> /var/log/citadel-digest.log 2>&1
```

Offsets are deliberate — the jobs touch the same `.db` files and `flock`
makes overlap safe rather than corrupting.
