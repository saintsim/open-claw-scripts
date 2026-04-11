# CLAUDE.md

## Repo overview

Shell scripts and supporting config for automating tasks on an OpenClaw-managed Mac Mini (running as the `openclaw` user). Scripts are designed to be triggered by launchd or OpenClaw's cron — they produce **no stdout** so OpenClaw's `announce` delivery has nothing to summarize or mangle.

## Structure

```
morning-briefing/
  briefing.sh                         # Main script — fetches RSS feeds, posts to Discord
  com.openclaw.morning-briefing.plist # launchd job definition (8 AM JST daily)
  SETUP.md                            # Step-by-step deployment instructions

api-billing-tracker/
  billing-tracker.sh                         # Fetches Claude API cost + Code plan %, posts to Discord
  com.openclaw.api-billing-tracker.plist     # launchd job definition (8 AM JST daily)
  SETUP.md                                   # Step-by-step deployment instructions

daily-market-update/
  market-update.sh                              # Fetches FX/equity/commodity prices from Yahoo Finance, posts to Discord
  com.openclaw.daily-market-update.plist        # launchd job definition (8 AM JST daily)
  SETUP.md                                      # Step-by-step deployment instructions
```

## Key conventions

- **No stdout from scripts.** All logging goes to `~/.openclaw/logs/<script>.log` via the `log()` helper. This is intentional — OpenClaw's agent delivery layer captures stdout and will summarize or announce it. Keeping stdout silent means the script controls its own output (posting directly to Discord).
- **Discord posting.** The default delivery method is a Discord webhook (`WEBHOOK_URL` in each script). There is also an alternative using OpenClaw's local HTTP API on `localhost:18789` — see the bottom of `morning-briefing/SETUP.md`.
- **Python for XML/JSON.** The scripts shell out to `python3` for feed parsing and JSON encoding rather than relying on `jq` or `xmllint`, since `python3` ships reliably with macOS.
- **Deploy path.** Scripts are deployed to `/Users/openclaw/.openclaw/workspace/<script-name>/` on the target Mac Mini, not run directly from this repo checkout.
- **All scheduling via launchd.** Every script in this repo is triggered by a `com.openclaw.<name>.plist` launchd agent installed to `~/Library/LaunchAgents/`. Do not use crontab or other schedulers — launchd handles wake-from-sleep catch-up correctly.
- **No LLM calls per run unless explicitly agreed.** Scripts must not call any AI model as part of their normal execution — each daily/scheduled run should be pure shell + HTTP + python3 data processing. This keeps costs predictable and avoids OpenClaw summarising intermediate output. The only documented exception is `api-billing-tracker`, which makes a single 1-token call to `claude-haiku` to read rate-limit response headers (noted in its SETUP.md and agreed with the repo owner). Any future exception must be documented in the relevant SETUP.md and noted here.

## Testing changes

There is no automated test suite. To validate `briefing.sh` changes:

1. Replace `WEBHOOK_URL` with a real webhook URL (or a test webhook).
2. Run the script directly: `bash morning-briefing/briefing.sh`
3. Check the log: `cat ~/.openclaw/logs/morning-briefing.log`
4. Confirm three Discord messages appear, one per feed source.

To test the launchd schedule without waiting for 8 AM:
```bash
launchctl start com.openclaw.morning-briefing
```

## What to watch out for

- The `WEBHOOK_URL` placeholder must never be committed as a real URL — it is a secret.
- The Mac timezone must be `Asia/Tokyo` for the 8 AM schedule to fire at the right time; the plist does not encode a timezone, it relies on the system clock.
- The `PATH` in the plist includes `/opt/homebrew/bin` for Apple Silicon Macs. If deploying to Intel, `/usr/local/bin` is the Homebrew prefix.
- Discord rate-limits webhooks to 5 messages per 2 seconds per webhook URL. The `sleep 1` between posts keeps the script comfortably under this limit.
