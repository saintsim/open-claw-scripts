#!/bin/bash
# api-billing-tracker/billing-tracker.sh
#
# Fetches monthly Claude API spend (via Anthropic admin API) and Claude Code
# plan usage (via a one-token haiku call purely to read rate-limit response
# headers), then posts a summary to Discord.
#
# Designed to run via launchd at 8 AM JST daily.
# Produces no meaningful stdout — OpenClaw-safe.

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration — edit these before deploying
# ---------------------------------------------------------------------------
ANTHROPIC_ADMIN_API_KEY="REPLACE_WITH_ANTHROPIC_ADMIN_API_KEY"
WEBHOOK_URL="REPLACE_WITH_DISCORD_WEBHOOK_URL"

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
LOG_FILE="${HOME}/.openclaw/logs/api-billing-tracker.log"
DATA_DIR="${HOME}/.openclaw/data/api-billing-tracker"

# ---------------------------------------------------------------------------
# Setup
# ---------------------------------------------------------------------------
mkdir -p "$(dirname "$LOG_FILE")" "$DATA_DIR"

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"
}

# ---------------------------------------------------------------------------
# Config validation
# ---------------------------------------------------------------------------
if [[ "$ANTHROPIC_ADMIN_API_KEY" == REPLACE_WITH_* ]]; then
  log "ERROR: ANTHROPIC_ADMIN_API_KEY not set — see SETUP.md"
  exit 1
fi
if [[ "$WEBHOOK_URL" == REPLACE_WITH_* ]]; then
  log "ERROR: WEBHOOK_URL not set — see SETUP.md"
  exit 1
fi

# ---------------------------------------------------------------------------
# Date helpers — python3 for macOS compat (avoids GNU date extensions)
# ---------------------------------------------------------------------------
TODAY=$(python3 -c "from datetime import date; print(date.today().isoformat())")
YESTERDAY=$(python3 -c "from datetime import date,timedelta; print((date.today()-timedelta(1)).isoformat())")
TODAY_MONTH=$(python3 -c "from datetime import date; print(date.today().strftime('%Y-%m'))")
YESTERDAY_MONTH=$(python3 -c "from datetime import date,timedelta; print((date.today()-timedelta(1)).strftime('%Y-%m'))")

MONTH_START_ISO=$(python3 -c "
from datetime import datetime, timezone
now = datetime.now(timezone.utc)
print(now.replace(day=1, hour=0, minute=0, second=0, microsecond=0).strftime('%Y-%m-%dT%H:%M:%SZ'))
")
NOW_ISO=$(python3 -c "
from datetime import datetime, timezone
print(datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'))
")

COST_FILE_TODAY="${DATA_DIR}/cost-${TODAY}.txt"
COST_FILE_YESTERDAY="${DATA_DIR}/cost-${YESTERDAY}.txt"

log "Starting (window: ${MONTH_START_ISO} → ${NOW_ISO})"

# ---------------------------------------------------------------------------
# 1. Monthly API token cost — GET /v1/organizations/cost_report
#    Requires an admin API key (sk-ant-admin...) from platform.claude.com.
#    Returns cost broken down per model/workspace; we sum everything.
# ---------------------------------------------------------------------------
log "Fetching cost_report..."
COST_JSON=$(curl -fsSL --max-time 30 \
  -H "x-api-key: ${ANTHROPIC_ADMIN_API_KEY}" \
  -H "anthropic-version: 2023-06-01" \
  "https://api.anthropic.com/v1/organizations/cost_report?starting_at=${MONTH_START_ISO}&ending_at=${NOW_ISO}") || {
  log "ERROR: cost_report request failed"
  exit 1
}
log "cost_report raw: ${COST_JSON}"

API_COST=$(python3 -c "
import json, sys

data = json.loads(sys.argv[1])

if 'error' in data:
    print(f'API error: {data[\"error\"]}', file=sys.stderr)
    sys.exit(1)

items = data.get('data', [data])
total = 0.0

for item in items:
    # Prefer total_cost; fall back to summing component cost fields
    if 'total_cost' in item:
        total += float(item['total_cost'] or 0)
    else:
        for f in ('input_cost', 'output_cost',
                  'cache_read_input_cost', 'cache_creation_input_cost'):
            total += float(item.get(f) or 0)

# Guard: if total > 500 it's likely in cents — convert to dollars
if total > 500:
    total /= 100.0

print(f'{total:.2f}')
" "$COST_JSON" 2>>"$LOG_FILE") || {
  log "ERROR: Failed to parse cost_report response"
  exit 1
}
log "API cost this month: \$${API_COST}"

# ---------------------------------------------------------------------------
# 2. Daily diff — compare today's monthly total to yesterday's
# ---------------------------------------------------------------------------
COST_DIFF=""
if [[ -f "$COST_FILE_YESTERDAY" && "$TODAY_MONTH" == "$YESTERDAY_MONTH" ]]; then
  YESTERDAY_COST=$(cat "$COST_FILE_YESTERDAY")
  COST_DIFF=$(python3 -c "
d    = float('${API_COST}') - float('${YESTERDAY_COST}')
sign = '+' if d >= 0 else '-'
print(f'{sign}\${abs(d):.2f}')
")
  log "Daily diff: ${COST_DIFF}"
fi

# Persist today's value for tomorrow's diff
echo "$API_COST" > "$COST_FILE_TODAY"

# Prune files older than 7 days (we only need yesterday's)
python3 -c "
import os, glob
from datetime import date, timedelta
cutoff = date.today() - timedelta(days=7)
for f in glob.glob('${DATA_DIR}/cost-*.txt'):
    stem = os.path.basename(f).replace('cost-','').replace('.txt','')
    try:
        if date.fromisoformat(stem) < cutoff:
            os.remove(f)
    except ValueError:
        pass
" 2>>"$LOG_FILE" || true

# ---------------------------------------------------------------------------
# 3. Claude Code plan usage
#
# We make the smallest possible API call (max_tokens=1) solely to read the
# anthropic-ratelimit-tokens-* response headers. On a Max plan these reflect
# the weekly token budget and include a reset timestamp ("til Sat 2pm").
#
# We use the OAuth access token Claude Code stores locally so the headers
# reflect the Max-plan limits, not the admin key's rate-tier limits.
#
# Cost of this call: ~$0.0000004 — negligible.
# ---------------------------------------------------------------------------
CODE_PLAN_LINE=""

fetch_code_plan() {
  local creds="${HOME}/.claude/.credentials.json"
  if [[ ! -f "$creds" ]]; then
    log "WARN: ${creds} not found — skipping Code plan metric (see SETUP.md)"
    return 0
  fi

  local token
  token=$(python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    d = json.load(f)
# Claude Code stores OAuth tokens under the 'claudeAiOauth' key
print(d.get('claudeAiOauth', {}).get('accessToken', ''))
" "$creds" 2>>"$LOG_FILE") || return 0

  if [[ -z "$token" ]]; then
    log "WARN: accessToken missing in ${creds} — skipping Code plan metric"
    return 0
  fi

  local hfile
  hfile=$(mktemp)

  if ! curl -fsS --max-time 30 \
      -X POST \
      -D "$hfile" \
      -H "Authorization: Bearer ${token}" \
      -H "anthropic-version: 2023-06-01" \
      -H "content-type: application/json" \
      -d '{"model":"claude-haiku-4-5-20251001","max_tokens":1,"messages":[{"role":"user","content":"1"}]}' \
      "https://api.anthropic.com/v1/messages" > /dev/null 2>>"$LOG_FILE"; then
    log "WARN: API call for Code plan rate-limit headers failed"
    rm -f "$hfile"
    return 0
  fi

  log "Rate-limit headers: $(cat "$hfile")"

  CODE_PLAN_LINE=$(python3 -c "
import sys, re
from datetime import datetime, timezone, timedelta

headers = open(sys.argv[1]).read()

def hval(name):
    m = re.search(rf'^{re.escape(name)}:\s*(.+)$', headers, re.I | re.M)
    return m.group(1).strip() if m else ''

limit_s     = hval('anthropic-ratelimit-tokens-limit')
remaining_s = hval('anthropic-ratelimit-tokens-remaining')
reset_s     = hval('anthropic-ratelimit-tokens-reset')

if not limit_s or not remaining_s:
    sys.exit(0)

limit     = float(limit_s)
remaining = float(remaining_s)
pct       = remaining / limit * 100 if limit > 0 else 0.0

til = ''
if reset_s:
    try:
        reset_dt = datetime.fromisoformat(reset_s.replace('Z', '+00:00'))
        secs = (reset_dt - datetime.now(timezone.utc)).total_seconds()
        # Only show reset if > 1 h away — that indicates a plan-level limit,
        # not a per-minute rate-limit window.
        if secs > 3600:
            jst = reset_dt + timedelta(hours=9)
            h   = jst.hour
            if   h == 0:  t = '12am'
            elif h < 12:  t = f'{h}am'
            elif h == 12: t = '12pm'
            else:         t = f'{h - 12}pm'
            til = f' (til {jst.strftime(\"%a\")} {t})'
    except Exception:
        pass

print(f'- Code - {pct:.0f}% remaining{til}')
" "$hfile" 2>>"$LOG_FILE") || CODE_PLAN_LINE=""

  rm -f "$hfile"
  log "Code plan: ${CODE_PLAN_LINE:-unavailable}"
}

fetch_code_plan || { log "WARN: fetch_code_plan exited unexpectedly"; }

# ---------------------------------------------------------------------------
# 4. Compose and post Discord message
# ---------------------------------------------------------------------------
if [[ -n "$COST_DIFF" ]]; then
  API_LINE="- API - \$${API_COST} this month (${COST_DIFF} in last 24h)"
else
  API_LINE="- API - \$${API_COST} this month"
fi

if [[ -n "$CODE_PLAN_LINE" ]]; then
  MSG="Claude bill update -

${API_LINE}
${CODE_PLAN_LINE}"
else
  MSG="Claude bill update -

${API_LINE}
- Code - unavailable (see SETUP.md)"
fi

POST_PAYLOAD=$(python3 -c "
import json, sys
print(json.dumps({'content': sys.argv[1]}))
" "$MSG")

curl -fsSL \
  -X POST \
  -H "Content-Type: application/json" \
  -d "$POST_PAYLOAD" \
  "$WEBHOOK_URL" \
  && log "Posted to Discord" \
  || log "ERROR: Discord webhook POST failed"

log "Done"
