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
# Uses the yfinance library, which handles Yahoo Finance rate-limiting and
# session management transparently.
#
# Symbols fetched:
#   JPYGBP=X  JPY/GBP exchange rate  (£ per ¥)
#   USDJPY=X  USD/JPY exchange rate  (¥ per $)
#   GS        Goldman Sachs stock
#   AAPL      Apple stock
#   ^GSPC     S&P 500 index
#   GC=F      Gold futures (spot proxy, $/oz)
#   SI=F      Silver futures (spot proxy, $/oz)
#   CL=F      WTI crude oil futures ($/bbl)
#
# Downloads 5 days of daily closes in one request. At 08:00 JST US markets
# are closed, so iloc[-1] = yesterday's close and iloc[-2] = the close before
# that, giving the prior-day move as the "change" figure.
# ---------------------------------------------------------------------------
MESSAGE=$(python3 << 'PYEOF'
import sys
from datetime import datetime

try:
    import yfinance as yf
except ImportError:
    print("ERROR: yfinance not installed — run: pip3 install yfinance", file=sys.stderr)
    sys.exit(1)

SYMBOLS = ["JPYGBP=X", "USDJPY=X", "GS", "AAPL", "^GSPC", "GC=F", "SI=F", "CL=F"]

try:
    data = yf.download(
        tickers=" ".join(SYMBOLS),
        period="5d",
        interval="1d",
        auto_adjust=True,
        progress=False,
        threads=True,
    )
except Exception as e:
    print(f"ERROR: yfinance download failed: {e}", file=sys.stderr)
    sys.exit(1)

if data.empty:
    print("ERROR: yfinance returned no data", file=sys.stderr)
    sys.exit(1)

# data["Close"] is a DataFrame with tickers as columns (multi-ticker download)
try:
    closes = data["Close"]
except KeyError:
    print("ERROR: no Close column in yfinance result", file=sys.stderr)
    sys.exit(1)

def fmt(sym, decimals=2, prefix=""):
    """Format one quote as  '$1,234.56  ▲ +3.21 (+0.26%)'"""
    try:
        series = closes[sym].dropna()
    except KeyError:
        return "N/A"
    if len(series) < 2:
        return "N/A"
    price  = float(series.iloc[-1])
    prev   = float(series.iloc[-2])
    change = price - prev
    pct    = (change / prev * 100) if prev != 0 else 0.0
    arrow  = "▲" if change >= 0 else "▼"
    sign   = "+" if change >= 0 else ""
    return (
        f"{prefix}{price:,.{decimals}f}  "
        f"{arrow} {sign}{change:.{decimals}f} ({sign}{pct:.2f}%)"
    )

today = datetime.now().strftime("%a %d %b %Y")

lines = [
    f"**Market Update — {today}**",
    "",
    "**FX**",
    f"• JPY/GBP:  {fmt('JPYGBP=X', 6)}",
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
