# Daily Market Update — Setup Instructions

These are exact, step-by-step instructions. Run every command as the `openclaw` user on the Mac Mini.

---

## What this does

A launchd job fires at 8 AM JST every day. It runs `market-update.sh`, which:

1. Fetches live quotes from Yahoo Finance (no API key required)
2. Formats a single Discord message with bullet points for each instrument
3. Shows the change vs the prior close for every line
4. POSTs the message to Discord via webhook

If the data fetch fails after all retries, a short failure notice is posted to Discord so the error is always visible in the channel. Full diagnostics are in the log.

No model runs at execution time. No agent commentary. Pure shell + Python + HTTP.

**Instruments tracked:**

| Instrument | Symbol |
|---|---|
| JPY/GBP FX rate | JPYGBP=X (falls back to 1/GBPJPY=X if unavailable) |
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
  python3 -m pip install yfinance
  ```

---

## Step 1 — Get a Discord Webhook URL

1. Open Discord → go to your **#market** channel
2. Click the gear icon (Edit Channel) → **Integrations** → **Webhooks**
3. Click **New Webhook** → copy the webhook URL
4. Keep this URL safe — you will paste it in Step 2

---

## Step 2 — Deploy the scripts

```bash
# Create the workspace directory
mkdir -p /Users/openclaw/.openclaw/workspace/daily-market-update

# Copy both scripts from this repo (market-update.sh calls market_data.py)
cp market-update.sh /Users/openclaw/.openclaw/workspace/daily-market-update/market-update.sh
cp market_data.py   /Users/openclaw/.openclaw/workspace/daily-market-update/market_data.py

# Make the shell script executable
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
• JPY/GBP:  0.005176  ▼ -0.000021 (-0.41%)
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

## Manual testing — simulating a different date

`market_data.py` can be run directly with a `--date` flag to override the header label. This is useful for checking output on demand without waiting for the 8 AM launchd run, or for simulating what a past day's post would have looked like.

```bash
cd /Users/openclaw/.openclaw/workspace/daily-market-update

# Run with today's date (same as the launchd job)
python3 market_data.py

# Simulate Saturday's post (data is always live — only the label changes)
python3 market_data.py --date "Sat 18 Apr 2026"
```

Note: market data is always fetched live from Yahoo Finance. The `--date` flag only changes the date label in the Discord message header. Running on Sunday with `--date "Sat 18 Apr 2026"` gives the same closes as Saturday's run would have seen, since yfinance returns historical data.

---

## If you need to stop it

```bash
launchctl unload -w \
  /Users/openclaw/Library/LaunchAgents/com.openclaw.daily-market-update.plist
```

---

## Data source notes

- **All data from Yahoo Finance via the `yfinance` library** — no API key, no account required
- `yfinance` handles session management; the script downloads 5 days of daily closes in a single request with a 60-second timeout per attempt
- **Retry behaviour**: if the download fails (timeout, network error, HTTP error), the script makes up to 5 attempts with a 2-second pause between each. If all attempts fail, a short failure notice is posted to Discord and the full error (including error type) is written to the log.
- **"Change vs prior close"** — at 8 AM JST, US markets have been closed for ~2–4 hours, so the latest close reflects the previous trading day and the change figure shows that day's move
- FX markets trade 24/7; at 8 AM JST the FX rates are live Asian-session prices and the change is vs the prior 5 PM EST roll
- If Yahoo Finance changes their data format, the log will show the yfinance version and the exact error — update `yfinance` first: `pip3 install --upgrade yfinance`
- **Weekends**: the launchd job fires every day. Saturday posts Friday's closing prices with Friday's real change vs Thursday — a useful post. Sunday posts "Markets closed today. Check back tomorrow." Monday posts "US markets open later today (~11:30pm JST). Next full update Tuesday." Both Sunday and Monday skip the yfinance fetch entirely — on Monday, FX/futures have technically reopened but daily bars won't close until 5pm EST, so yfinance would just return Friday's data again (identical to Saturday's post).
- **US market holidays (Tue–Sat runs)**: if a US holiday closed equities or commodity futures the previous day but FX still traded (e.g. Thanksgiving, Memorial Day, Good Friday), the affected instruments show "market closed" and FX shows the live Asian-session price. This is detected automatically by comparing each symbol's last close date against the FX reference date.
- **Global FX holidays (Christmas Day, New Year's Day)**: when FX and all markets are simultaneously closed, `_compute_ref_date` falls back to yesterday. Since all instruments share the same last close date (the day before the holiday), no "market closed" labels are shown — which is correct. The update will display the last available prices with no explicit holiday notice.

---

## Troubleshooting

| Symptom | Fix |
|---|---|
| Discord shows "data fetch failed" | Check the log — look for `Attempt N/5 failed:` entries which show the error type (timeout, HTTP 429 rate limit, HTTP 403 IP block, network failure, etc.) |
| Discord shows "script failed unexpectedly" | Check the log — look for the last entry before "EXIT trap fired" |
| Log says `ERROR: WEBHOOK_URL not set` | Edit `market-update.sh` and replace the placeholder |
| Log shows `timed out after 60s` on all 5 attempts | Intermittent Yahoo Finance connectivity at 8 AM JST — the retry count or timeout can be increased in `market_data.py` (`_DOWNLOAD_TIMEOUT`, `_DOWNLOAD_RETRIES`) |
| Log shows `rate limited by Yahoo Finance (HTTP 429)` | Yahoo Finance is throttling requests — wait and retry manually, or increase `_DOWNLOAD_RETRY_DELAY` |
| Log shows `ERROR: yfinance not installed` | The log prints the exact command needed, e.g. `/usr/bin/python3 -m pip install yfinance`. Run that exact command — not `pip3 install` — to install into the same interpreter the script uses. |
| One symbol shows `N/A` | That symbol may have changed ticker on Yahoo Finance. Check at finance.yahoo.com |
| One symbol shows `market closed` unexpectedly | Check the log for `ref_date=` — if it shows today's date the partial intra-day bar filter may have failed; check yfinance version |
| Job doesn't run at 8 AM | Confirm Mac timezone is Asia/Tokyo. Confirm plist is loaded: `launchctl list \| grep daily-market-update` |
| `python3 not found` | Run `which python3`. If missing: `brew install python3` |

---

## Running the tests

The Python logic lives in `market_data.py` and has a pytest suite in `tests/`.
No internet connection is required — `yf.download` is mocked throughout.

```bash
python3 -m pip install pytest pandas yfinance
pytest daily-market-update/tests/
```

Expected output: `34 passed`.

---

## No LLM calls

This script makes no AI model calls. Data processing is pure Python (`yfinance`, `json`). This is consistent with the repo policy documented in `CLAUDE.md`.
