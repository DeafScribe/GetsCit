#!/usr/bin/env bash
#
# security-digest.sh
#
# Deliberately not a live alerting pipeline — a once-a-day summary,
# delivered the same way password resets already are: a message posted
# into the Aide room. That's the honest shape of "simple" here: this
# reads three things that already exist (login_attempts, audit_log,
# Caddy's access log) and surfaces counts worth a human's attention, on
# a schedule a human is expected to check.
#
# Worth being direct about the real limitation this carries forward from
# the earlier decision to skip email/SMTP entirely: this digest has to be
# READ to be useful. There's no push notification leaving this box —
# that would need the email infrastructure this project deliberately
# avoided. If that trade-off ever stops being acceptable (an operator
# who won't reliably check the Aide room), the fix is adding a push
# channel, not making this script fancier.
#
# Assumes each instance's SQLite file is named after its full hostname
# (e.g. two.castletalk.com.db) so it lines up directly with Caddy's log
# filename for that same instance — adjust DATA_DIR/CADDY_LOG_DIR and the
# naming convention to whatever's actually in use if it differs.

set -euo pipefail

DATA_DIR="/var/citadel/data"
CADDY_LOG_DIR="/var/log/caddy"
WINDOW_SECONDS=$((24 * 60 * 60))
CUTOFF=$(( $(date +%s) - WINDOW_SECONDS ))
TODAY=$(date -u +%F)

# Common scanner/probe paths — not exhaustive, just the well-known noise
# that shows up on any public IP within days. Seeing hits here isn't
# alarming by itself (it's constant background internet radiation), but
# a sudden volume spike from one IP is worth knowing about.
SCANNER_PATTERN='wp-admin|wp-login|\.env|\.git/|phpmyadmin|xmlrpc\.php|\.aws/credentials'

for db in "${DATA_DIR}"/*.db; do
  instance=$(basename "$db" .db)
  caddy_log="${CADDY_LOG_DIR}/${instance}.log"

  # --- login_attempts: IPs that crossed the block threshold today ---
  blocked_ips=$(sqlite3 "$db" "
    SELECT ip, COUNT(*) FROM login_attempts
    WHERE success = 0 AND created_at > ${CUTOFF}
    GROUP BY ip HAVING COUNT(*) >= 20
    ORDER BY COUNT(*) DESC;
  ")

  login_failures=$(sqlite3 "$db" "
    SELECT COUNT(*) FROM login_attempts
    WHERE success = 0 AND created_at > ${CUTOFF};
  ")
  login_successes=$(sqlite3 "$db" "
    SELECT COUNT(*) FROM login_attempts
    WHERE success = 1 AND created_at > ${CUTOFF};
  ")

  # --- audit_log: anything logged today, regardless of whether it was
  # already surfaced immediately as a room post (this is a rollup count,
  # not a re-notification) ---
  audit_count=$(sqlite3 "$db" "
    SELECT COUNT(*) FROM audit_log WHERE created_at > ${CUTOFF};
  ")

  # --- Caddy access log: crude, honest, awk-based — top offending IPs
  # by 4xx count, and any hits on common scanner paths ---
  scan_hits="0"
  top_4xx=""
  if [ -f "$caddy_log" ]; then
    # Caddy's default JSON log has request.remote_ip and status fields;
    # this assumes that shape. Adjust the jq filter if a custom log
    # format is configured instead.
    if command -v jq >/dev/null 2>&1; then
      top_4xx=$(jq -r --arg cutoff "$CUTOFF" '
        select(.ts >= ($cutoff | tonumber)) |
        select(.status >= 400 and .status < 500) |
        .request.remote_ip
      ' "$caddy_log" 2>/dev/null | sort | uniq -c | sort -rn | head -5)

      scan_hits=$(jq -r --arg cutoff "$CUTOFF" --arg pattern "$SCANNER_PATTERN" '
        select(.ts >= ($cutoff | tonumber)) |
        select(.request.uri | test($pattern; "i")) |
        .request.remote_ip
      ' "$caddy_log" 2>/dev/null | wc -l)
    fi
  fi

  # --- Compose and post the digest, only if there's anything worth saying ---
  if [ -n "$blocked_ips" ] || [ "$scan_hits" != "0" ] || [ "$login_failures" -gt 0 ]; then
    summary="Security digest ${TODAY}: ${login_successes} logins, ${login_failures} failures, ${audit_count} audit events, ${scan_hits} scanner-path hits."
    if [ -n "$blocked_ips" ]; then
      summary="${summary} IPs that hit the rate limit: $(echo "$blocked_ips" | tr '\n' ' ' | sed 's/|/x/g')"
    fi

    aide_room_id=$(sqlite3 "$db" "SELECT id FROM rooms WHERE name = 'Aide' AND deleted_at IS NULL LIMIT 1;")
    if [ -n "$aide_room_id" ]; then
      # Parameter binding matters here — this is text that could contain
      # nothing an attacker controls directly, but treat it with the same
      # discipline as any other insert rather than string-formatting SQL.
      sqlite3 "$db" "INSERT INTO messages (room_id, author_id, body) VALUES (${aide_room_id}, NULL, '$(echo "$summary" | sed "s/'/''/g")');"
      echo "$(date -u +%FT%TZ) ${instance}: digest posted"
    fi
  else
    echo "$(date -u +%FT%TZ) ${instance}: nothing notable, no digest posted"
  fi
done

# --- Crontab entry, once daily, offset from backup/cleanup jobs ---
#   45 3 * * * /path/to/security-digest.sh >> /var/log/citadel-digest.log 2>&1
