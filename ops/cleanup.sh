#!/usr/bin/env bash
#
# cleanup.sh   (supersedes cleanup-login-attempts.sh — renamed because it
#               now prunes two tables, not one)
#
# Prunes the two tables that grow without bound and hold nothing worth
# keeping:
#
#   login_attempts — deleted past 5 days. Zero ongoing value once the
#     rate-limiting windows that use them have passed (15 min for
#     username backoff, 10 min for IP thresholds); 5 days is pure
#     retention margin for an operator glancing back at recent activity,
#     not a security requirement.
#
#   sessions — deleted once expires_at has passed. Without this, every
#     login ever performed leaves a row behind forever. Expired rows are
#     already refused at auth time, so deleting them changes no
#     behaviour; it just stops the table growing.
#
# Neither table is part of the incremental archive backup — both are
# operational state, not durable community data. See backup.sh's
# exclusion list.
#
# Adjust DATA_DIR to wherever the per-instance .db files actually live.

set -euo pipefail

DATA_DIR="/var/citadel/data"
RETENTION_DAYS=5
NOW_EPOCH=$(date +%s)
CUTOFF_EPOCH=$(( NOW_EPOCH - RETENTION_DAYS * 86400 ))

shopt -s nullglob
for db in "${DATA_DIR}"/*.db; do
  attempts=$(sqlite3 "$db" "
    DELETE FROM login_attempts WHERE created_at < ${CUTOFF_EPOCH};
    SELECT changes();
  ")
  sessions=$(sqlite3 "$db" "
    DELETE FROM sessions WHERE expires_at < ${NOW_EPOCH};
    SELECT changes();
  ")
  echo "$(date -u +'%Y-%m-%dT%H:%M:%SZ') ${db}: ${attempts} login_attempts, ${sessions} sessions deleted"
done

# --- Crontab entry (run once daily, e.g. 03:17 to avoid the top of the
# hour when other cron jobs commonly cluster) ---
#
#   17 3 * * * flock -n /tmp/citadel-cleanup.lock /path/to/cleanup.sh >> /var/log/citadel-cleanup.log 2>&1
#
# flock guards against overlapping with backup.sh (03:23), which touches
# the same .db files.
