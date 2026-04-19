#!/bin/bash
# daily-market-update/market-update.sh
#
# Fetches FX rates, equity prices, and commodity prices via the yfinance
# Python library and posts a formatted daily market summary to Discord.
#
# Designed to run via launchd at 8 AM JST daily.
# Produces no meaningful stdout — OpenClaw-safe.
#
# Prerequisite: pip3 install yfinance  (see SETUP.md)

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration — edit these before deploying
# ---------------------------------------------------------------------------
WEBHOOK_URL="REPLACE_WITH_YOUR_DISCORD_WEBHOOK_URL"

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
LOG_FILE="${HOME}/.openclaw/logs/daily-market-update.log"

# ---------------------------------------------------------------------------
# Setup
# ---------------------------------------------------------------------------
mkdir -p "$(dirname "$LOG_FILE")"

DISCORD_POSTED=false

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
    "$WEBHOOK_URL" && DISCORD_POSTED=true
}

# If the script exits for any reason without having posted to Discord,
# send a fallback notice so the failure is always visible in the channel.
trap 'if [[ "$DISCORD_POSTED" == false ]]; then
  post_to_discord "**Market Update** — script failed unexpectedly. Check \`daily-market-update.log\`." || true
  log "Posted unexpected failure notice to Discord"
fi' EXIT

log "Starting daily-market-update"

# ---------------------------------------------------------------------------
# Sunday / Monday: no complete daily bars available — post a heartbeat
# and exit. (date +%u: 1=Mon … 7=Sun)
#
# Sunday:  markets closed all day.
# Monday:  FX/futures just reopened but daily bars won't close until
#          5pm EST Monday, so yfinance would return Friday's data again —
#          identical to Saturday's post.
#
# Adding a future notice day: add a case entry with NOTICE and NOTICE_LABEL.
# ---------------------------------------------------------------------------
DAY=$(date +%u)
NOTICE=""
NOTICE_LABEL=""
case "$DAY" in
  7) NOTICE="**Market Update** — Markets closed today. Check back tomorrow."
     NOTICE_LABEL="Sunday" ;;
  1) NOTICE="**Market Update** — US markets open later today (~11:30pm JST). Next full update Tuesday."
     NOTICE_LABEL="Monday" ;;
esac

if [[ -n "$NOTICE" ]]; then
  post_to_discord "$NOTICE" \
    && log "$NOTICE_LABEL: posted notice" \
    || { log "ERROR: Discord webhook POST failed ($NOTICE_LABEL notice)"; exit 1; }
  exit 0
fi

# ---------------------------------------------------------------------------
# Fetch and format market data via market_data.py
#
# market_data.py uses the yfinance library (pip3 install yfinance) to
# download 5 days of daily closes for FX, equity, and commodity symbols.
# At 08:00 JST US markets are closed, so iloc[-1] = yesterday's close and
# iloc[-2] = the prior close, giving the previous day's move.
#
# Stderr is redirected to the log so yfinance error messages are captured.
# On failure a notice is posted to Discord so the error is visible.
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if ! MESSAGE=$(python3 "${SCRIPT_DIR}/market_data.py" 2>>"$LOG_FILE"); then
  log "ERROR: market_data.py failed — see above for details"
  post_to_discord "**Market Update** — data fetch failed. Check \`daily-market-update.log\`." \
    && log "Posted failure notice to Discord" \
    || log "ERROR: could not post failure notice to Discord"
  exit 1
fi

if [[ -z "$MESSAGE" ]]; then
  log "ERROR: market_data.py produced no output"
  exit 1
fi

log "Market data fetched and formatted"

# ---------------------------------------------------------------------------
# Post to Discord
# ---------------------------------------------------------------------------
post_to_discord "$MESSAGE" \
  && log "Posted to Discord" \
  || { log "ERROR: Discord webhook POST failed"; exit 1; }

log "Done"
