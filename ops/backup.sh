#!/usr/bin/env bash
#
# backup.sh
#
# Baseline + incremental-delta model, per instance:
#   - Monthly: a full consolidated copy (VACUUM INTO), so restore never has
#     to replay an ever-growing chain back to the beginning of time.
#   - Daily: only rows that are new or changed since the last run.
#
# Two categories of table, handled differently, because they behave
# differently:
#
#   APPEND-ONLY (messages, chat_messages) — rows are never edited after
#   insert. "New since last time" is fully captured by `id > watermark`.
#
#   MUTABLE (users, rooms, content_pages, site_config, chat_sessions) —
#   rows get edited after creation (password changes, room renames, config
#   edits, a chat session's ended_at being set later). `id > watermark`
#   would miss those edits entirely, since the row already existed. These
#   are tracked by `updated_at` instead, and replayed with REPLACE INTO
#   (upsert by primary key) rather than plain INSERT, so a later delta
#   correctly overwrites an earlier snapshot of the same row.
#
# EXCLUDED ENTIRELY: login_attempts. It's operational noise with its own
# 5-day cleanup job, not durable community data — nothing here should
# reconstruct failed-login history after a restore.
#
# KNOWN LIMITATION, worth being honest about rather than pretending it's
# solved: this design captures inserts and updates, but not deletions. If
# a row is ever hard-deleted (a room removed, an account purged) between
# one baseline and the next, a restore from baseline+deltas will silently
# resurrect it, because a deleted row leaves no watermark trace to
# replay. Nothing in this system currently deletes rows that way, so this
# is a forward-looking flag, not an active bug — but if a "delete room" or
# "delete account" feature ever gets built, it needs a soft-delete column
# (deleted_at, treated as a mutable-table update) rather than a real
# DELETE, or backups will quietly diverge from what a restore produces.
#
# ALSO STILL OPEN: chat_sessions was originally specified without an
# updated_at column. It needs one added (its ended_at transition is
# exactly the kind of "existing row gets edited later" case this script
# is built to handle) — add it before relying on this for that table.

set -euo pipefail

DATA_DIR="/var/citadel/data"
STATE_DIR="/var/citadel/backup-state"
ARCHIVE_DIR="/var/citadel/backup-archive"
BASELINE_DIR="${ARCHIVE_DIR}/baseline"
DELTA_DIR="${ARCHIVE_DIR}/deltas"

mkdir -p "$STATE_DIR" "$BASELINE_DIR" "$DELTA_DIR"

APPEND_TABLES=(messages chat_messages audit_log)
MUTABLE_TABLES=(users rooms floors content_pages site_config chat_sessions read_state)

# DELIBERATELY EXCLUDED from both lists, each for its own reason:
#   login_attempts — ephemeral rate-limiting arithmetic, 5-day retention
#   sessions       — restoring a session token resurrects a live credential
#   aide_status    — resets to all-offline on boot; restoring it restores a lie
# Note that `floors` was added to the schema without being added here at
# the time; caught and corrected. Any new mutable table needs a line in
# this array or it silently never gets backed up — there is no error for
# a table that simply isn't listed.

TODAY=$(date -u +%Y%m%d)
DAY_OF_MONTH=$(date -u +%d)

get_watermark() {
  local file="$1"
  [ -f "$file" ] && cat "$file" || echo 0
}

for db in "${DATA_DIR}"/*.db; do
  instance=$(basename "$db" .db)
  lockfile="/tmp/citadel-backup-${instance}.lock"

  # Don't touch a .db file that the login-attempts cleanup job (or another
  # backup run) might be writing to at the same moment.
  exec {lock_fd}>"$lockfile"
  if ! flock -n "$lock_fd"; then
    echo "$(date -u +%FT%TZ) ${instance}: skipped, already locked"
    continue
  fi

  # --- Monthly baseline ---
  if [ "$DAY_OF_MONTH" = "01" ]; then
    baseline_file="${BASELINE_DIR}/${instance}-$(date -u +%Y%m).db"
    sqlite3 "$db" "VACUUM INTO '${baseline_file}'"
    echo "$(date -u +%FT%TZ) ${instance}: baseline taken -> ${baseline_file}"
    # NOTE: old deltas for this instance are NOT deleted here anymore.
    # They're superseded once the new baseline is confirmed shipped
    # off-site (see ship_offsite, below) — deleting them immediately,
    # before that confirmation, risks losing both the old deltas AND the
    # new baseline in the same window if shipping then fails partway.
  fi

  # --- Daily incremental: append-only tables, keyed by id ---
  for table in "${APPEND_TABLES[@]}"; do
    wm_file="${STATE_DIR}/${instance}.${table}.watermark"
    last_id=$(get_watermark "$wm_file")
    out_file="${DELTA_DIR}/${instance}-${table}-${TODAY}.sql"

    sqlite3 "$db" <<SQL > "$out_file"
.mode insert ${table}
SELECT * FROM ${table} WHERE id > ${last_id};
SQL

    if [ -s "$out_file" ]; then
      new_max=$(sqlite3 "$db" "SELECT MAX(id) FROM ${table} WHERE id > ${last_id};")
      echo "$new_max" > "$wm_file"
    else
      rm -f "$out_file"
    fi
  done

  # --- Daily incremental: mutable tables, keyed by updated_at, upsert on replay ---
  for table in "${MUTABLE_TABLES[@]}"; do
    wm_file="${STATE_DIR}/${instance}.${table}.watermark"
    last_ts=$(get_watermark "$wm_file")
    out_file="${DELTA_DIR}/${instance}-${table}-${TODAY}.sql"

    sqlite3 "$db" <<SQL | sed 's/^INSERT INTO/REPLACE INTO/' > "$out_file"
.mode insert ${table}
SELECT * FROM ${table} WHERE updated_at > ${last_ts};
SQL

    if [ -s "$out_file" ]; then
      new_max=$(sqlite3 "$db" "SELECT MAX(updated_at) FROM ${table} WHERE updated_at > ${last_ts};")
      echo "$new_max" > "$wm_file"
    else
      rm -f "$out_file"
    fi
  done

  echo "$(date -u +%FT%TZ) ${instance}: incremental complete"
  flock -u "$lock_fd"
done

# --- Off-site shipping ---
#
# rclone: single open-source binary, ~40+ backends (S3, R2, Backblaze B2,
# GCS, Azure, Dropbox, etc.) under one consistent command set. It's a
# transport tool, not a versioning one — it copies files as they exist
# locally, it doesn't keep history of its own. That's fine here because
# this script's OWN output already is the versioning: baseline files are
# dated by month and deltas by day, nothing gets overwritten in place
# locally, so a plain `rclone copy` (never `rclone sync`, which mirrors
# deletions too) just needs to land those already-immutable files
# remotely. Configure the remote once with `rclone config` — this script
# assumes a remote named `citadel-backup` pointing at whatever
# provider/bucket you choose; that credential setup is a one-time step
# outside this script, not something to hardcode here.
#
# If built-in client-side encryption matters to you beyond whatever your
# provider does at rest, rclone's `crypt` remote wraps any of the above
# backends — no second tool needed for that; restic would be the
# alternative if you specifically wanted its snapshot/dedup semantics on
# top, but this script already provides the versioning restic would add,
# so plain rclone is the simpler correct fit here rather than composing
# both.
REMOTE="citadel-backup:castletalk-backups"

if command -v rclone >/dev/null 2>&1; then
  if rclone copy "$ARCHIVE_DIR" "$REMOTE" --checksum; then
    echo "$(date -u +%FT%TZ) shipped archive to ${REMOTE}"
    # Only now, with this month's baselines confirmed uploaded, prune the
    # local deltas each instance's baseline superseded. Doing this here
    # instead of at baseline-creation time above closes the window where
    # a shipping failure could have left neither the deltas nor a
    # confirmed remote baseline recoverable.
    if [ "$DAY_OF_MONTH" = "01" ]; then
      for db in "${DATA_DIR}"/*.db; do
        instance=$(basename "$db" .db)
        rm -f "${DELTA_DIR}/${instance}"-*.sql
      done
      echo "$(date -u +%FT%TZ) pruned local deltas superseded by this month's baseline"
    fi
  else
    echo "ERROR: rclone copy failed — local deltas retained, nothing pruned" >&2
    exit 1
  fi
else
  echo "WARNING: rclone not installed. Backups are LOCAL ONLY." >&2
fi

# --- Crontab entry, once daily ---
#   23 3 * * * /path/to/backup.sh >> /var/log/citadel-backup.log 2>&1
#
# Deliberately offset from cleanup-login-attempts.sh's 03:17 slot so the
# two don't contend for the same lock unnecessarily, even though the
# flock above makes overlap safe rather than corrupting, either way.
