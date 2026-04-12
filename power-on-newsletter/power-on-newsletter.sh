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

# ---------------------------------------------------------------------------
# Setup
# ---------------------------------------------------------------------------
mkdir -p "${HOME}/.openclaw/logs" "${HOME}/.openclaw/data"

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
# try_fetch_and_post
# Runs newsletter_fetcher.py and, if a new newsletter is found, posts it
# to Discord and persists the seen article ID.
#
# Returns:
#   0 — newsletter found and posted successfully
#   1 — no new newsletter (not in feed, or already seen); caller should retry
#   2 — hard error; caller should exit 1
#
# Note: newsletter_fetcher.py exit codes (0=new, 1=error, 2=not-found) are
# remapped so that 0 always means success and non-zero signals the problem.
# ---------------------------------------------------------------------------
try_fetch_and_post() {
  local result=""
  local fetch_exit=0
  result=$(python3 "${SCRIPT_DIR}/newsletter_fetcher.py") || fetch_exit=$?

  if [[ $fetch_exit -eq 1 ]]; then
    log "ERROR: newsletter_fetcher.py failed (fetch/parse error)"
    return 2
  fi

  if [[ $fetch_exit -eq 2 ]]; then
    log "No new newsletter found in feed"
    return 1
  fi

  # Exit code 0 — parse all fields from the JSON result in a single python3
  # invocation to avoid spawning four separate interpreter processes.
  local archive_url date_human headline article_id state_file
  {
    IFS= read -r archive_url
    IFS= read -r date_human
    IFS= read -r headline
    IFS= read -r article_id
    IFS= read -r state_file
  } < <(python3 -c "
import json, sys
d = json.loads(sys.argv[1])
print(d['archive_url'])
print(d['date_human'])
print(d['headline'])
print(d['article_id'])
print(d['state_file'])
" "$result")

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

  # Persist the seen article ID only after a successful Discord post.
  # The state file path comes from newsletter_fetcher.py (single source of truth).
  echo "$article_id" > "$state_file"
  log "Saved last-seen article ID"

  return 0
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
log "Starting power-on-newsletter"

# First attempt — use || to capture the return code without triggering set -e
attempt_result=0
try_fetch_and_post || attempt_result=$?

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
attempt_result=0
try_fetch_and_post || attempt_result=$?

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
