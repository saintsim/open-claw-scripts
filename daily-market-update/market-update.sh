#!/bin/bash
# daily-market-update/market-update.sh
#
# Fetches FX rates, equity prices, and commodity prices via the yfinance
# Python library and posts a formatted daily market summary to Discord.
#
# Designed to run via launchd at 8 AM JST daily.
# Produces no meaningful stdout — OpenClaw-safe.
#
# Prerequisite: python3 available (yfinance is installed automatically)

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration — edit these before deploying
# ---------------------------------------------------------------------------
WEBHOOK_URL="REPLACE_WITH_YOUR_DISCORD_WEBHOOK_URL"

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
VENV_PYTHON="${SCRIPT_DIR}/venv/bin/python3"
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
# Uses system python3 (stdlib only) so it works even if the venv is absent.
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
trap 'log "EXIT trap fired (DISCORD_POSTED=${DISCORD_POSTED})"
if [[ "$DISCORD_POSTED" == false ]]; then
  post_to_discord "**Market Update** — script failed unexpectedly. Check \`daily-market-update.log\`." || true
  log "Posted unexpected failure notice to Discord"
fi' EXIT

log "Starting daily-market-update"

# ---------------------------------------------------------------------------
# Python bootstrap
#
# Priority order:
#   1. Use the venv if it already has yfinance (fast path — every normal run)
#   2. Create/repair the venv and pip install yfinance (first run or repairs)
#   3. Fall back to any system Python that already has yfinance installed
#      (handles cases where pip install has no write permission or fails)
# ---------------------------------------------------------------------------
PYTHON=""

# Fast path: venv exists and has yfinance
if [[ -x "$VENV_PYTHON" ]] && "$VENV_PYTHON" -c "import yfinance" 2>/dev/null; then
  PYTHON="$VENV_PYTHON"
  log "Using venv Python: $("$PYTHON" --version 2>&1) — ${PYTHON}"
else
  # Try to create or repair the venv
  log "venv not ready — attempting to create at ${SCRIPT_DIR}/venv..."
  if python3 -m venv "${SCRIPT_DIR}/venv" 2>>"$LOG_FILE" \
      && "${SCRIPT_DIR}/venv/bin/pip" install --quiet yfinance >>"$LOG_FILE" 2>&1; then
    PYTHON="$VENV_PYTHON"
    log "venv ready: $("$PYTHON" --version 2>&1) — ${PYTHON}"
  else
    # Venv setup failed — search common locations for a Python with yfinance
    log "WARNING: venv setup failed — searching for a system Python with yfinance"
    for candidate in \
        /opt/homebrew/bin/python3 \
        /usr/local/bin/python3 \
        /usr/bin/python3 \
        /Applications/Xcode.app/Contents/Developer/usr/bin/python3; do
      if [[ -x "$candidate" ]] && "$candidate" -c "import yfinance" 2>/dev/null; then
        PYTHON="$candidate"
        log "Falling back to: $("$PYTHON" --version 2>&1) — ${PYTHON}"
        break
      fi
    done
  fi
fi

if [[ -z "$PYTHON" ]]; then
  log "ERROR: no Python with yfinance found — install yfinance or fix venv (see SETUP.md)"
  exit 1
fi

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
log "Day of week: $DAY (1=Mon…7=Sun)"
NOTICE=""
NOTICE_LABEL=""
case "$DAY" in
  7) NOTICE="**Market Update** — Markets closed today. Check back tomorrow."
     NOTICE_LABEL="Sunday" ;;
  1) NOTICE="**Market Update** — US markets open later today (~11:30pm JST). Next full update Tuesday."
     NOTICE_LABEL="Monday" ;;
esac

if [[ -n "$NOTICE" ]]; then
  log "Posting $NOTICE_LABEL notice..."
  post_to_discord "$NOTICE" \
    && log "$NOTICE_LABEL: posted notice" \
    || { log "ERROR: Discord webhook POST failed ($NOTICE_LABEL notice)"; exit 1; }
  exit 0
fi

# ---------------------------------------------------------------------------
# Fetch and format market data via market_data.py
#
# Uses the resolved $PYTHON so yfinance is always available regardless of
# which python3 is in PATH at 08:00 JST.
# Stderr is redirected to the log so yfinance error messages are captured.
# On failure a notice is posted to Discord so the error is visible.
# ---------------------------------------------------------------------------
log "Running market_data.py (${SCRIPT_DIR}/market_data.py)..."
if ! MESSAGE=$("$PYTHON" "${SCRIPT_DIR}/market_data.py" 2>>"$LOG_FILE"); then
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

log "Market data fetched and formatted (${#MESSAGE} chars)"

# ---------------------------------------------------------------------------
# Post to Discord
# ---------------------------------------------------------------------------
log "Posting to Discord (${#MESSAGE} chars)..."
post_to_discord "$MESSAGE" \
  && log "Posted to Discord successfully" \
  || { log "ERROR: Discord webhook POST failed"; exit 1; }

log "Done"
