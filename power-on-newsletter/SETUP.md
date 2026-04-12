# Power On Newsletter Archiver — Setup Instructions

These are exact, step-by-step instructions. Run every command as the `openclaw` user on the Mac Mini.

---

## What this does

A launchd job fires at 00:00 JST every Monday. It runs `power-on-newsletter.sh`, which:

1. Fetches Mark Gurman's Bloomberg author RSS feed
2. Finds the first item whose URL contains `/news/newsletters/`
3. Strips query parameters and constructs an `https://archive.md/<url>` link
4. Extracts the publication date and headline from the RSS item
5. POSTs one Discord message containing the date, headline, and archive link

If no newsletter is found at midnight (Gurman sometimes publishes in the early hours), the script waits 60 minutes and tries again. If still nothing, it posts **"No newsletter published this week."**

Deduplication is handled via `~/.openclaw/data/power-on-newsletter-last-seen.txt` — the script only posts if the article path has changed since the last successful post.

No model runs at execution time. Pure shell + Python + HTTP.

---

## Prerequisites

- Mac Mini timezone must be set to **Asia/Tokyo** (JST)
  - Check: `sudo systemsetup -gettimezone`
  - Set if needed: `sudo systemsetup -settimezone Asia/Tokyo`
- `python3` available (confirm: `python3 --version`)
- `curl` available (ships with macOS)

No extra Python libraries required — only the standard library (`urllib`, `xml.etree.ElementTree`, `json`) is used.

---

## Step 1 — Get a Discord Webhook URL

1. Open Discord → go to your target channel
2. Click the gear icon (Edit Channel) → **Integrations** → **Webhooks**
3. Click **New Webhook** → copy the webhook URL
4. Keep this URL safe — you will paste it in Step 2

---

## Step 2 — Deploy the scripts

```bash
# Create the workspace directory
mkdir -p /Users/openclaw/.openclaw/workspace/power-on-newsletter

# Copy both files from this repo
cp power-on-newsletter.sh /Users/openclaw/.openclaw/workspace/power-on-newsletter/
cp newsletter_fetcher.py  /Users/openclaw/.openclaw/workspace/power-on-newsletter/

# Make the shell script executable
chmod +x /Users/openclaw/.openclaw/workspace/power-on-newsletter/power-on-newsletter.sh

# Insert your webhook URL (replace the placeholder)
nano /Users/openclaw/.openclaw/workspace/power-on-newsletter/power-on-newsletter.sh
# Change this line:
#   WEBHOOK_URL="REPLACE_WITH_YOUR_DISCORD_WEBHOOK_URL"
# To your actual webhook URL, e.g.:
#   WEBHOOK_URL="https://discord.com/api/webhooks/123456789/abcdef..."
```

---

## Step 3 — Test the script manually

Run it now and verify the message appears in your Discord channel:

```bash
/Users/openclaw/.openclaw/workspace/power-on-newsletter/power-on-newsletter.sh
```

Check the log for any errors:

```bash
cat /Users/openclaw/.openclaw/logs/power-on-newsletter.log
```

**Expected Discord message format:**

```
Power On — 12 April 2026
Apple AI Glasses Will Rival Meta's With Several Styles, Oval Cameras
https://archive.md/https://www.bloomberg.com/news/newsletters/2026-04-12/apple-ai-glasses-...
```

If you run it a second time immediately, the script should post nothing (deduplication kicks in — the last-seen ID matches). Confirm by checking the log:

```
[...] No new newsletter found in feed
```

---

## Step 4 — Install the launchd job

```bash
# Copy the plist to the LaunchAgents directory
cp com.openclaw.power-on-newsletter.plist \
   /Users/openclaw/Library/LaunchAgents/com.openclaw.power-on-newsletter.plist

# Load it (registers with launchd — will fire next Monday at 00:00)
launchctl load -w \
  /Users/openclaw/Library/LaunchAgents/com.openclaw.power-on-newsletter.plist

# Verify it is loaded
launchctl list | grep power-on-newsletter
```

You should see a line like:

```
-   0   com.openclaw.power-on-newsletter
```

The `-` in the first column means it is not currently running (correct — it only runs on Monday at midnight).

---

## Verifying the schedule

```bash
# Check timezone
sudo systemsetup -gettimezone
# Should say: Asia/Tokyo

# Force a test run right now (optional)
launchctl start com.openclaw.power-on-newsletter

# Watch the log in real time
tail -f /Users/openclaw/.openclaw/logs/power-on-newsletter.log
```

---

## If you need to stop it

```bash
launchctl unload -w \
  /Users/openclaw/Library/LaunchAgents/com.openclaw.power-on-newsletter.plist
```

---

## Resetting the last-seen state

To force the script to repost even if the article was already seen (e.g. for testing):

```bash
rm ~/.openclaw/data/power-on-newsletter-last-seen.txt
```

---

## How deduplication works

After a successful Discord post, `power-on-newsletter.sh` writes the article's URL path (e.g. `/news/newsletters/2026-04-12/apple-ai-glasses-...`) to:

```
~/.openclaw/data/power-on-newsletter-last-seen.txt
```

On the next run, `newsletter_fetcher.py` compares the latest feed item's path against this file. If they match, it exits with code 2 (no new newsletter) without posting.

---

## How the retry works

If `newsletter_fetcher.py` returns "no newsletter" (exit code 2), the shell script sleeps 3600 seconds (1 hour) and tries again. Power On typically publishes Sunday evening US time, which lands in the early hours Monday JST. The two-attempt window covers this.

If neither attempt finds a newsletter, the script posts:
```
Power On — No newsletter published this week.
```
and exits cleanly.

---

## Troubleshooting

| Symptom | Fix |
|---|---|
| Log says `ERROR: WEBHOOK_URL not set` | Edit `power-on-newsletter.sh` and replace the placeholder with your actual webhook URL |
| Log says `Failed to fetch RSS feed` | Check internet. Try `curl -fsSL https://www.bloomberg.com/authors/AS7Hj1mBMGM/mark-gurman.rss` manually |
| Log says `No new newsletter found` on a Monday | Newsletter may not be published yet. The script will retry after 60 minutes. |
| Script posts "No newsletter this week" but there is one | The RSS feed may have returned no `/news/newsletters/` link. Check: `curl -fsSL https://www.bloomberg.com/authors/AS7Hj1mBMGM/mark-gurman.rss \| grep newsletters` |
| Same newsletter posted twice | The state file was deleted or corrupted. Check `~/.openclaw/data/power-on-newsletter-last-seen.txt` |
| Job doesn't run on Monday | Confirm Mac timezone is Asia/Tokyo. Confirm plist loaded: `launchctl list \| grep power-on-newsletter` |
| `python3 not found` | Run `which python3`. If missing: `brew install python3` |

---

## Running the tests

The Python logic lives in `newsletter_fetcher.py` and has a pytest suite in `tests/`. No internet access required.

```bash
pip3 install pytest
pytest power-on-newsletter/tests/
```

---

## No LLM calls

This script makes no AI model calls. All processing is pure Python standard library. This is consistent with the repo policy documented in `CLAUDE.md`.
