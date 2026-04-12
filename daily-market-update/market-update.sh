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

log "Starting daily-market-update"

# ---------------------------------------------------------------------------
# Sunday: markets closed — post a short notice and exit
# (date +%u: 1=Mon … 7=Sun)
# ---------------------------------------------------------------------------
if [[ "$(date +%u)" == "7" ]]; then
  post_to_discord "**Market Update** — Markets closed today. Check back tomorrow." \
    && log "Sunday: posted closed notice" \
    || { log "ERROR: Discord webhook POST failed (closed notice)"; exit 1; }
  exit 0
fi

# ---------------------------------------------------------------------------
# Fetch and format market data
#
# Uses the yfinance library, which handles Yahoo Finance rate-limiting and
# session management transparently.
#
# Symbols fetched:
#   JPYGBP=X  JPY/GBP rate (preferred, £ per ¥)
#   GBPJPY=X  GBP/JPY rate (fallback — inverted to produce JPY/GBP if
#             JPYGBP=X is unavailable on Yahoo Finance)
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

# GBPJPY=X is fetched alongside JPYGBP=X as a fallback in case the latter
# is not published by Yahoo Finance.
SYMBOLS = ["JPYGBP=X", "GBPJPY=X", "USDJPY=X", "GS", "AAPL", "^GSPC", "GC=F", "SI=F", "CL=F"]

try:
    data = yf.download(
        tickers=" ".join(SYMBOLS),
        period="5d",
        interval="1d",
        auto_adjust=True,
        progress=False,
    )
except Exception as e:
    print(f"ERROR: yfinance download failed: {e}", file=sys.stderr)
    sys.exit(1)

if data.empty:
    print("ERROR: yfinance returned no data", file=sys.stderr)
    sys.exit(1)

try:
    closes = data["Close"]
except KeyError:
    print("ERROR: no Close column in yfinance result", file=sys.stderr)
    sys.exit(1)

def _render(price, prev, decimals, prefix=""):
    """Shared formatter used by fmt() and fmt_jpygbp()."""
    change = price - prev
    pct    = (change / prev * 100) if prev != 0 else 0.0
    arrow  = "▲" if change >= 0 else "▼"
    sign   = "+" if change >= 0 else ""
    return (
        f"{prefix}{price:,.{decimals}f}  "
        f"{arrow} {sign}{change:.{decimals}f} ({sign}{pct:.2f}%)"
    )

def fmt(sym, decimals=2, prefix=""):
    """Format a standard quote: look up sym in closes and render."""
    try:
        series = closes[sym].dropna()
    except KeyError:
        return "N/A"
    if len(series) < 2:
        return "N/A"
    return _render(float(series.iloc[-1]), float(series.iloc[-2]), decimals, prefix)

def fmt_jpygbp():
    """JPY/GBP rate with fallback: try JPYGBP=X directly; if unavailable,
    compute 1/GBPJPY=X. Both paths resolve price/prev then call _render.
    Note: pct change of 1/x is approximately but not exactly −1× the pct
    change of x (the bases differ; they converge for small daily moves)."""
    price = prev = None

    # Preferred: direct JPYGBP=X quote
    try:
        series = closes["JPYGBP=X"].dropna()
        if len(series) >= 2:
            price, prev = float(series.iloc[-1]), float(series.iloc[-2])
    except KeyError:
        pass

    # Fallback: invert GBPJPY=X
    if price is None:
        try:
            series = closes["GBPJPY=X"].dropna()
            if len(series) >= 2:
                g, g_prev = float(series.iloc[-1]), float(series.iloc[-2])
                if g != 0 and g_prev != 0:
                    price, prev = 1.0 / g, 1.0 / g_prev
        except KeyError:
            pass

    if price is None or prev is None:
        return "N/A"
    return _render(price, prev, 6)

today = datetime.now().strftime("%a %d %b %Y")

lines = [
    f"**Market Update — {today}**",
    "",
    "**FX**",
    f"• JPY/GBP:  {fmt_jpygbp()}",
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

# set -euo pipefail exits if the Python block above fails.
# This guard catches the rare edge case where Python exits 0 but prints nothing.
if [[ -z "$MESSAGE" ]]; then
  log "ERROR: Python produced no output"
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
