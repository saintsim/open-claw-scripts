# Daily Market Update — Setup Instructions

These are exact, step-by-step instructions. Run every command as the `openclaw` user on the Mac Mini.

---

## What this does

A launchd job fires at 8 AM JST every day. It runs `market-update.sh`, which:

1. Fetches live quotes from Yahoo Finance (no API key required)
2. Formats a single Discord message with bullet points for each instrument
3. Shows the change vs the prior close for every line
4. POSTs the message to Discord via webhook

No model runs at execution time. No agent commentary. Pure shell + Python + HTTP.

**Instruments tracked:**

| Instrument | Symbol |
|---|---|
| GBP/JPY FX rate | GBPJPY=X |
| USD/JPY FX rate | USDJPY=X |
| Goldman Sachs stock | GS |
| Apple stock | AAPL |
| S&P 500 index | ^GSPC |
| Gold futures ($/oz) | GC=F |
| Silver futures ($/oz) | SI=F |
| WTI crude oil futures ($/bbl) | CL=F |

---

## Prerequisites

- Mac Mini timezone must be set to **Asia/Tokyo** (JST)
  - Check: `sudo systemsetup -gettimezone`
  - Set if needed: `sudo systemsetup -settimezone Asia/Tokyo`
- `python3` available (confirm: `python3 --version`)
- `curl` available (ships with macOS)
- `yfinance` Python library installed:
  ```bash
  pip3 install yfinance
  ```

---

## Step 1 — Get a Discord Webhook URL

1. Open Discord → go to your **#market** channel
2. Click the gear icon (Edit Channel) → **Integrations** → **Webhooks**
3. Click **New Webhook** → copy the webhook URL
4. Keep this URL safe — you will paste it in Step 2

---

## Step 2 — Deploy the script

```bash
# Create the workspace directory
mkdir -p /Users/openclaw/.openclaw/workspace/daily-market-update

# Copy the script from this repo
cp market-update.sh /Users/openclaw/.openclaw/workspace/daily-market-update/market-update.sh

# Make it executable
chmod +x /Users/openclaw/.openclaw/workspace/daily-market-update/market-update.sh

# Insert your webhook URL
nano /Users/openclaw/.openclaw/workspace/daily-market-update/market-update.sh
# Change this line:
#   WEBHOOK_URL="REPLACE_WITH_YOUR_DISCORD_WEBHOOK_URL"
# To your actual webhook URL, e.g.:
#   WEBHOOK_URL="https://discord.com/api/webhooks/123456789/abcdef..."
```

---

## Step 3 — Test the script manually

Run it now and verify the message appears in your Discord channel:

```bash
/Users/openclaw/.openclaw/workspace/daily-market-update/market-update.sh
```

Check the log for any errors:

```bash
cat /Users/openclaw/.openclaw/logs/daily-market-update.log
```

**Expected output in Discord:**

```
Market Update — Fri 11 Apr 2025

FX
• GBP/JPY:  193.45  ▲ +0.80 (+0.41%)
• USD/JPY:  149.82  ▼ -0.31 (-0.21%)

Equities
• Goldman Sachs (GS):  $485.20  ▲ +3.50 (+0.73%)
• Apple (AAPL):        $198.45  ▼ -1.20 (-0.60%)
• S&P 500:             5,234.18  ▲ +12.50 (+0.24%)

Commodities
• Gold ($/oz):         $2,345.60  ▲ +8.20 (+0.35%)
• Silver ($/oz):       $29.450  ▲ +0.150 (+0.51%)
• WTI Crude ($/bbl):   $78.90  ▼ -0.45 (-0.57%)

Change vs prior close
```

---

## Step 4 — Install the launchd job

```bash
# Copy the plist to the LaunchAgents directory
cp com.openclaw.daily-market-update.plist \
   /Users/openclaw/Library/LaunchAgents/com.openclaw.daily-market-update.plist

# Load it (registers with launchd — will fire next time 8 AM arrives)
launchctl load -w \
  /Users/openclaw/Library/LaunchAgents/com.openclaw.daily-market-update.plist

# Verify it is loaded
launchctl list | grep daily-market-update
```

You should see a line like:
```
-   0   com.openclaw.daily-market-update
```

The `-` in the first column means it is not currently running (correct — it only runs at 8 AM).

---

## Verifying the schedule

```bash
# Check timezone
sudo systemsetup -gettimezone
# Should say: Asia/Tokyo

# Force a test run right now (optional)
launchctl start com.openclaw.daily-market-update

# Watch the log in real time
tail -f /Users/openclaw/.openclaw/logs/daily-market-update.log
```

---

## If you need to stop it

```bash
launchctl unload -w \
  /Users/openclaw/Library/LaunchAgents/com.openclaw.daily-market-update.plist
```

---

## Data source notes

- **All data from Yahoo Finance via the `yfinance` library** — no API key, no account required
- `yfinance` handles session management and rate-limiting transparently; the script downloads 5 days of daily closes in a single request
- **"Change vs prior close"** — at 8 AM JST, US markets have been closed for ~2–4 hours, so the latest close reflects the previous trading day and the change figure shows that day's move
- FX markets trade 24/7; at 8 AM JST the FX rates are live Asian-session prices and the change is vs the prior 5 PM EST roll
- If Yahoo Finance changes their data format, the log will show `ERROR: yfinance download failed` or a symbol will show `N/A` — update `yfinance` first: `pip3 install --upgrade yfinance`

---

## Troubleshooting

| Symptom | Fix |
|---|---|
| Log says `ERROR: WEBHOOK_URL not set` | Edit `market-update.sh` and replace the placeholder |
| Log says `ERROR: yfinance download failed` | Check internet. Try `python3 -c "import yfinance as yf; print(yf.download('AAPL', period='2d', progress=False))"` |
| Log says `ERROR: yfinance not installed` | Run `pip3 install yfinance` |
| One symbol shows `N/A` | That symbol may have changed ticker on Yahoo Finance. Check at finance.yahoo.com |
| Job doesn't run at 8 AM | Confirm Mac timezone is Asia/Tokyo. Confirm plist is loaded: `launchctl list \| grep daily-market-update` |
| `python3 not found` | Run `which python3`. If missing: `brew install python3` |

---

## No LLM calls

This script makes no AI model calls. Data processing is pure Python (`yfinance`, `json`). This is consistent with the repo policy documented in `CLAUDE.md`.
