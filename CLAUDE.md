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
  market-update.sh                              # Shell entry point — day-of-week logic, calls market_data.py, posts to Discord
  market_data.py                                # Python module — fetches + formats market data (testable standalone)
  com.openclaw.daily-market-update.plist        # launchd job definition (8 AM JST daily)
  SETUP.md                                      # Step-by-step deployment instructions
  tests/
    conftest.py                                 # pytest path setup
    test_market_data.py                         # Unit tests for market_data.py (mocks yf.download)
```

## Key conventions

- **No stdout from scripts.** All logging goes to `~/.openclaw/logs/<script>.log` via the `log()` helper. This is intentional — OpenClaw's agent delivery layer captures stdout and will summarize or announce it. Keeping stdout silent means the script controls its own output (posting directly to Discord).
- **Discord posting.** The default delivery method is a Discord webhook (`WEBHOOK_URL` in each script). There is also an alternative using OpenClaw's local HTTP API on `localhost:18789` — see the bottom of `morning-briefing/SETUP.md`.
- **Python in a separate file, not a heredoc.** Any non-trivial Python logic must live in a dedicated `<name>.py` file alongside the bash script — not embedded as a heredoc inside bash. The bash script calls it with `python3 "${SCRIPT_DIR}/<name>.py"`. One-liner invocations (e.g. JSON-encoding a string) may remain inline. See `daily-market-update/` for the reference implementation.
- **Python style and version.** Follow PEP 8. Target Python 3.13 (the latest stable release available via `brew install python` on macOS as of 2025). Key rules: two blank lines between top-level definitions, `snake_case` names, explicit keyword arguments where they aid readability, `if __name__ == "__main__":` guard so the module is importable by tests without side effects, and lazy-import any heavy dependency (e.g. `import yfinance`) inside the function that needs it for the same reason.
- **Tests for every Python module.** Each `<name>.py` must have a corresponding `tests/test_<name>.py` pytest suite. Tests must pass without internet access — mock all external API and network calls. Use `patch.dict(sys.modules, ...)` to mock library imports, and pass mock data directly to pure functions so the bulk of the tests never touch the network layer at all. A `tests/conftest.py` that adds the parent directory to `sys.path` is the standard way to make the module importable. Run with: `pytest <script-dir>/tests/`
- **Python for XML/JSON.** The scripts shell out to `python3` for feed parsing and JSON encoding rather than relying on `jq` or `xmllint`, since `python3` ships reliably with macOS.
- **Deploy path.** Scripts are deployed to `/Users/openclaw/.openclaw/workspace/<script-name>/` on the target Mac Mini, not run directly from this repo checkout. Deploy both the `.sh` and any `.py` files together — the bash script locates Python modules relative to itself via `SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"`.
- **All scheduling via launchd.** Every script in this repo is triggered by a `com.openclaw.<name>.plist` launchd agent installed to `~/Library/LaunchAgents/`. Do not use crontab or other schedulers — launchd handles wake-from-sleep catch-up correctly.
- **No LLM calls per run unless explicitly agreed.** Scripts must not call any AI model as part of their normal execution — each daily/scheduled run should be pure shell + HTTP + python3 data processing. This keeps costs predictable and avoids OpenClaw summarising intermediate output. The only documented exception is `api-billing-tracker`, which makes a single 1-token call to `claude-haiku` to read rate-limit response headers (noted in its SETUP.md and agreed with the repo owner). Any future exception must be documented in the relevant SETUP.md and noted here.

## Testing changes

**Scripts with a Python module** — run the pytest suite (no internet required):
```bash
pip3 install pytest pandas  # plus any script-specific deps
pytest <script-dir>/tests/
```

**Pure bash scripts** (no `.py` module) — test manually:

1. Replace `WEBHOOK_URL` with a real or test webhook URL.
2. Run directly: `bash <script-dir>/<script>.sh`
3. Check the log: `cat ~/.openclaw/logs/<script>.log`
4. Confirm the expected Discord message(s) appear.

To trigger a launchd job immediately without waiting for 8 AM:
```bash
launchctl start com.openclaw.<name>
```

## What to watch out for

- The `WEBHOOK_URL` placeholder must never be committed as a real URL — it is a secret.
- The Mac timezone must be `Asia/Tokyo` for the 8 AM schedule to fire at the right time; the plist does not encode a timezone, it relies on the system clock.
- The `PATH` in the plist includes `/opt/homebrew/bin` for Apple Silicon Macs. If deploying to Intel, `/usr/local/bin` is the Homebrew prefix.
- Discord rate-limits webhooks to 5 messages per 2 seconds per webhook URL. The `sleep 1` between posts keeps the script comfortably under this limit.
