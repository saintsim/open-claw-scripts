#!/bin/bash
# daily-market-update/market-update.sh
#
# Fetches FX rates, equity prices, and commodity prices from Yahoo Finance
# and posts a formatted daily market summary to Discord via webhook.
#
# Designed to run via launchd at 8 AM JST daily.
# Produces no meaningful stdout — OpenClaw-safe.

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

log "Starting daily-market-update"

# ---------------------------------------------------------------------------
# Fetch and format market data
#
# Uses Yahoo Finance v7 quote API (no API key required).
# Python handles: cookie seeding, crumb fetching, quote request, formatting.
#
# Symbols fetched:
#   GBPJPY=X  GBP/JPY exchange rate  (¥ per £)
#   USDJPY=X  USD/JPY exchange rate  (¥ per $)
#   GS        Goldman Sachs stock
#   AAPL      Apple stock
#   ^GSPC     S&P 500 index
#   GC=F      Gold futures (spot proxy, $/oz)
#   SI=F      Silver futures (spot proxy, $/oz)
#   CL=F      WTI crude oil futures ($/bbl)
#
# "Change" figures come from Yahoo's regularMarketChange /
# regularMarketChangePercent fields — i.e. change vs prior close.
# ---------------------------------------------------------------------------
MESSAGE=$(python3 << 'PYEOF'
import json, sys
import urllib.request, urllib.parse
import http.cookiejar
from datetime import datetime

UA = (
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
    "AppleWebKit/537.36 (KHTML, like Gecko) "
    "Chrome/120.0.0.0 Safari/537.36"
)
BASE_HEADERS = {
    "User-Agent": UA,
    "Accept-Language": "en-US,en;q=0.9",
}

# Cookie-aware opener so Yahoo Finance sets the session cookie
cj = http.cookiejar.CookieJar()
opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(cj))

def get_url(url, extra_headers=None):
    h = dict(BASE_HEADERS)
    if extra_headers:
        h.update(extra_headers)
    req = urllib.request.Request(url, headers=h)
    with opener.open(req, timeout=25) as r:
        return r.read().decode("utf-8", errors="replace")

# Step 1: Seed cookies (best-effort — non-fatal if it fails)
try:
    get_url("https://finance.yahoo.com/")
except Exception:
    pass

# Step 2: Fetch crumb (required by Yahoo Finance v7 quote API)
crumb = ""
try:
    crumb = get_url(
        "https://query1.finance.yahoo.com/v1/test/getcrumb",
        {"Referer": "https://finance.yahoo.com/"},
    ).strip()
except Exception as e:
    print(f"WARN: crumb fetch failed ({e})", file=sys.stderr)

# Step 3: Fetch quotes for all symbols in one request
SYMBOLS = ["GBPJPY=X", "USDJPY=X", "GS", "AAPL", "^GSPC", "GC=F", "SI=F", "CL=F"]
params = "symbols=" + urllib.parse.quote(",".join(SYMBOLS))
if crumb:
    params += "&crumb=" + urllib.parse.quote(crumb)
quote_url = "https://query1.finance.yahoo.com/v7/finance/quote?" + params

try:
    raw = get_url(quote_url, {
        "Accept": "application/json",
        "Referer": "https://finance.yahoo.com/",
    })
    data = json.loads(raw)
except Exception as e:
    print(f"ERROR: quote fetch failed: {e}", file=sys.stderr)
    sys.exit(1)

quotes = data.get("quoteResponse", {}).get("result", [])
if not quotes:
    api_err = data.get("quoteResponse", {}).get("error") or ""
    print(f"ERROR: empty quote result. API error: {api_err}", file=sys.stderr)
    sys.exit(1)

by_sym = {q["symbol"]: q for q in quotes}

def fmt(sym, decimals=2, prefix=""):
    """Format a single quote as  '1,234.56  ▲ +3.21 (+0.26%)'"""
    q = by_sym.get(sym)
    if not q:
        return "N/A"
    price  = q.get("regularMarketPrice")
    change = q.get("regularMarketChange") or 0.0
    pct    = q.get("regularMarketChangePercent") or 0.0
    if price is None:
        return "N/A"
    arrow = "▲" if change >= 0 else "▼"
    sign  = "+" if change >= 0 else ""
    return (
        f"{prefix}{price:,.{decimals}f}  "
        f"{arrow} {sign}{change:.{decimals}f} ({sign}{pct:.2f}%)"
    )

today = datetime.now().strftime("%a %d %b %Y")

lines = [
    f"**Market Update — {today}**",
    "",
    "**FX**",
    f"• GBP/JPY:  {fmt('GBPJPY=X')}",
    f"• USD/JPY:  {fmt('USDJPY=X')}",
    "",
    "**Equities**",
    f"• Goldman Sachs (GS):  {fmt('GS', prefix='$')}",
    f"• Apple (AAPL):        {fmt('AAPL', prefix='$')}",
    f"• S&P 500:             {fmt('^GSPC')}",
    "",
    "**Commodities**",
    f"• Gold ($/oz):         {fmt('GC=F', prefix='$')}",
    f"• Silver ($/oz):       {fmt('SI=F', 3, '$')}",
    f"• WTI Crude ($/bbl):   {fmt('CL=F', prefix='$')}",
    "",
    "_Change vs prior close_",
]

print("\n".join(lines))
PYEOF
)

py_exit=$?
if [[ $py_exit -ne 0 ]]; then
  log "ERROR: data fetch/format step failed (exit ${py_exit})"
  exit 1
fi

if [[ -z "$MESSAGE" ]]; then
  log "ERROR: Python produced no output"
  exit 1
fi

log "Market data fetched and formatted"

# ---------------------------------------------------------------------------
# Post to Discord webhook
# ---------------------------------------------------------------------------
POST_PAYLOAD=$(python3 -c "
import json, sys
print(json.dumps({'content': sys.argv[1]}))
" "$MESSAGE")

curl -fsSL \
  -X POST \
  -H "Content-Type: application/json" \
  -d "$POST_PAYLOAD" \
  "$WEBHOOK_URL" \
  && log "Posted to Discord" \
  || { log "ERROR: Discord webhook POST failed"; exit 1; }

log "Done"
