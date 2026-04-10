#!/bin/bash
# morning-briefing/briefing.sh
#
# Fetches the 5 most recent headlines from BBC News, Japan Times, and MacRumors
# and posts them directly to Discord via webhook.
#
# Designed to run via launchd (or OpenClaw cron) at 8 AM JST daily.
# Posts straight to the webhook — no agent summarization involved.
# Produces no meaningful stdout so OpenClaw's announce delivery has nothing to mangle.

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration — edit these before deploying
# ---------------------------------------------------------------------------
WEBHOOK_URL="REPLACE_WITH_YOUR_DISCORD_WEBHOOK_URL"

ARTICLES_PER_FEED=5

FEED_NAMES=("BBC News" "Japan Times" "MacRumors")
FEED_URLS=(
  "https://feeds.bbci.co.uk/news/rss.xml"
  "https://www.japantimes.co.jp/feed/"
  "https://feeds.macrumors.com/MacRumors-All"
)

LOG_FILE="${HOME}/.openclaw/logs/morning-briefing.log"

# ---------------------------------------------------------------------------
# Setup
# ---------------------------------------------------------------------------
mkdir -p "$(dirname "$LOG_FILE")"

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"
}

if [[ "$WEBHOOK_URL" == "REPLACE_WITH_YOUR_DISCORD_WEBHOOK_URL" ]]; then
  log "ERROR: WEBHOOK_URL not set. Edit briefing.sh and replace the placeholder."
  exit 1
fi

# ---------------------------------------------------------------------------
# fetch_headlines <feed_url> <count>
# Outputs one "[title](url)" line per article, up to <count> articles.
# Handles both RSS 2.0 (<item>) and Atom (<entry>) feeds.
# ---------------------------------------------------------------------------
fetch_headlines() {
  local url="$1"
  local count="$2"

  curl -fsSL --max-time 30 "$url" | python3 -c "
import sys
import xml.etree.ElementTree as ET

count = int('${count}')
content = sys.stdin.read()

try:
    root = ET.fromstring(content)
except ET.ParseError as e:
    print(f'[parse error: {e}]', file=sys.stderr)
    sys.exit(0)

NS_ATOM = 'http://www.w3.org/2005/Atom'

# RSS 2.0 uses <item>; Atom uses <entry>
items = root.findall('.//item')
if not items:
    items = root.findall(f'.//{{{NS_ATOM}}}entry')

results = []
for item in items[:count]:
    # --- Title ---
    t = item.find('title')
    if t is None:
        t = item.find(f'{{{NS_ATOM}}}title')
    title = ' '.join((t.text or '').split()) if t is not None else ''

    # --- Link ---
    # RSS 2.0: <link> text content
    # Atom:    <link href=\"...\"> attribute
    link = ''
    lel = item.find('link')
    if lel is not None:
        link = (lel.get('href') or lel.text or '').strip()
    if not link:
        lel = item.find(f'{{{NS_ATOM}}}link')
        if lel is not None:
            link = (lel.get('href') or lel.text or '').strip()

    if title and link:
        results.append(f'• [{title}]({link})')

print('\n'.join(results))
"
}

# ---------------------------------------------------------------------------
# post_to_discord <message_text>
# Safely JSON-encodes the content and POSTs to the webhook.
# ---------------------------------------------------------------------------
post_to_discord() {
  local content="$1"

  local payload
  payload=$(python3 -c "
import json, sys
content = sys.argv[1]
print(json.dumps({'content': content}))
" "$content")

  curl -fsSL \
    -X POST \
    -H "Content-Type: application/json" \
    -d "$payload" \
    "$WEBHOOK_URL"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
log "Starting morning briefing"

for i in "${!FEED_NAMES[@]}"; do
  name="${FEED_NAMES[$i]}"
  url="${FEED_URLS[$i]}"

  log "Fetching: $name"

  headlines=""
  headlines=$(fetch_headlines "$url" "$ARTICLES_PER_FEED") || {
    log "WARN: curl/parse failed for $name ($url)"
    continue
  }

  if [[ -z "$headlines" ]]; then
    log "WARN: No headlines extracted from $name"
    continue
  fi

  # Bold source header + links
  message="**${name}**
${headlines}"

  post_to_discord "$message" \
    && log "Posted: $name" \
    || log "ERROR: Webhook POST failed for $name"

  # Brief pause to stay well under Discord's rate limit (5 msg/2s per webhook)
  sleep 1
done

log "Done"
