#!/bin/bash
# power-on-newsletter/power-on-newsletter.sh
#
# Fetches Mark Gurman's Power On newsletter from Bloomberg via RSS and
# posts an archive.md link, headline, and date to Discord via webhook.
#
# Designed to run via launchd every Monday at 00:00 JST. If the newsletter
# has not yet been published at midnight, the script retries once after 60
# minutes. If still not found, it posts a "no newsletter this week" notice.
#
# Posts nothing and exits silently if the latest newsletter was already
# seen on a prior run (deduplication via ~/.openclaw/data/).
#
# Produces no meaningful stdout — OpenClaw-safe.

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration — edit these before deploying
# ---------------------------------------------------------------------------
WEBHOOK_URL="REPLACE_WITH_YOUR_DISCORD_WEBHOOK_URL"

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOG_FILE="${HOME}/.openclaw/logs/power-on-newsletter.log"
STATE_FILE="${HOME}/.openclaw/data/power-on-newsletter-last-seen.txt"

# ---------------------------------------------------------------------------
# Setup
# ---------------------------------------------------------------------------
mkdir -p "$(dirname "$LOG_FILE")" "$(dirname "$STATE_FILE")"

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"
}

# ---------------------------------------------------------------------------
# Config validation
# ---------------------------------------------------------------------------
if [[ "$WEBHOOK_URL" == REPLACE_WITH_* ]]; then
  log "ERROR: WEBHOOK_URL not set — see SETUP.md"
  exit 1
fi

# ---------------------------------------------------------------------------
# post_to_discord <message>
# JSON-encodes content and POSTs to the webhook.
# ---------------------------------------------------------------------------
post_to_discord() {
  local content="$1"

  local payload
  payload=$(python3 -c "
import json, sys
print(json.dumps({'content': sys.argv[1]}))
" "$content")

  curl -fsSL \
    -X POST \
    -H "Content-Type: application/json" \
    -d "$payload" \
    "$WEBHOOK_URL"
}

# ---------------------------------------------------------------------------
# fetch_newsletter
# Calls newsletter_fetcher.py; captures stdout (JSON) and propagates the
# exit code without triggering set -e (handled by the caller).
# ---------------------------------------------------------------------------
fetch_newsletter() {
  python3 "${SCRIPT_DIR}/newsletter_fetcher.py"
}

# ---------------------------------------------------------------------------
# try_fetch_and_post
# Attempt a single fetch. Returns:
#   0 — newsletter found and posted (caller should exit)
#   1 — newsletter already seen or not in feed (caller should retry/give up)
#   2 — hard error (caller should exit 1)
# ---------------------------------------------------------------------------
try_fetch_and_post() {
  local result=""
  local fetch_exit=0
  result=$(fetch_newsletter) || fetch_exit=$?

  if [[ $fetch_exit -eq 1 ]]; then
    log "ERROR: newsletter_fetcher.py failed (fetch/parse error)"
    return 2
  fi

  if [[ $fetch_exit -eq 2 ]]; then
    log "No new newsletter found in feed"
    return 1
  fi

  # Exit code 0 — parse the JSON result
  local archive_url date_human headline article_id
  archive_url=$(python3 -c "import json,sys; print(json.loads(sys.argv[1])['archive_url'])" "$result")
  date_human=$(python3 -c "import json,sys; print(json.loads(sys.argv[1])['date_human'])" "$result")
  headline=$(python3 -c "import json,sys; print(json.loads(sys.argv[1])['headline'])" "$result")
  article_id=$(python3 -c "import json,sys; print(json.loads(sys.argv[1])['article_id'])" "$result")

  log "New newsletter found: ${date_human:-unknown date} — ${headline}"
  log "Archive URL: ${archive_url}"

  local message
  if [[ -n "$date_human" ]]; then
    message="**Power On** — ${date_human}
${headline}
${archive_url}"
  else
    message="**Power On**
${headline}
${archive_url}"
  fi

  post_to_discord "$message" \
    && log "Posted to Discord" \
    || { log "ERROR: Webhook POST failed"; return 2; }

  # Persist the seen article ID only after a successful Discord post
  echo "$article_id" > "$STATE_FILE"
  log "Saved last-seen article ID"

  return 0
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
log "Starting power-on-newsletter"

# First attempt
try_fetch_and_post
attempt_result=$?

if [[ $attempt_result -eq 2 ]]; then
  log "Exiting due to error"
  exit 1
fi

if [[ $attempt_result -eq 0 ]]; then
  log "Done"
  exit 0
fi

# No newsletter found — wait 60 minutes and try once more.
# Power On is weekly; Gurman sometimes publishes in the early hours Monday.
log "Waiting 60 minutes before retry"
sleep 3600

log "Retrying fetch"
try_fetch_and_post
attempt_result=$?

if [[ $attempt_result -eq 2 ]]; then
  log "Exiting due to error on retry"
  exit 1
fi

if [[ $attempt_result -eq 0 ]]; then
  log "Done"
  exit 0
fi

# Still nothing after retry — post a notice and exit cleanly
log "No newsletter after retry — posting notice"
post_to_discord "**Power On** — No newsletter published this week." \
  && log "Posted: no newsletter notice" \
  || log "ERROR: Webhook POST failed (no newsletter notice)"

log "Done"
