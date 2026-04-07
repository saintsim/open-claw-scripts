# Morning Briefing — Setup Instructions for Claude Haiku

These are exact, step-by-step instructions. Run every command as the `openclaw` user on the Mac Mini.

---

## What this does

A launchd job fires at 8 AM JST every day. It runs `briefing.sh`, which:

1. Fetches the 5 most recent articles from BBC News, Japan Times, and MacRumors
2. Formats each as a Discord markdown link: `[Headline title](https://...)`
3. POSTs three separate messages to Discord via webhook — one per source

No model runs at execution time. No agent commentary. No summarization.

---

## Prerequisites

- Mac Mini timezone must be set to **Asia/Tokyo** (JST)
  - Check: `sudo systemsetup -gettimezone`
  - Set if needed: `sudo systemsetup -settimezone Asia/Tokyo`
- `python3` available (confirm: `python3 --version`)
- `curl` available (ships with macOS)

---

## Step 1 — Get a Discord Webhook URL

1. Open Discord → go to your **#briefing** channel
2. Click the gear icon (Edit Channel) → **Integrations** → **Webhooks**
3. Click **New Webhook** → copy the webhook URL
4. Keep this URL safe — you will paste it in Step 2

---

## Step 2 — Deploy the script

```bash
# Create the workspace directory if it doesn't exist
mkdir -p /Users/openclaw/.openclaw/workspace/morning-briefing

# Copy the script from this repo
cp briefing.sh /Users/openclaw/.openclaw/workspace/morning-briefing/briefing.sh

# Make it executable
chmod +x /Users/openclaw/.openclaw/workspace/morning-briefing/briefing.sh

# Insert your webhook URL (replace the placeholder)
# Open the file and edit the WEBHOOK_URL line:
nano /Users/openclaw/.openclaw/workspace/morning-briefing/briefing.sh
# Change this line:
#   WEBHOOK_URL="REPLACE_WITH_YOUR_DISCORD_WEBHOOK_URL"
# To your actual webhook URL, e.g.:
#   WEBHOOK_URL="https://discord.com/api/webhooks/123456789/abcdef..."
```

---

## Step 3 — Test the script manually

Run it now and verify three messages appear in #briefing:

```bash
/Users/openclaw/.openclaw/workspace/morning-briefing/briefing.sh
```

Check the log for any errors:

```bash
cat /Users/openclaw/.openclaw/logs/morning-briefing.log
```

If you see `[parse error]` or `WARN: No headlines`, check your internet connection and that the feed URLs are reachable.

---

## Step 4 — Install the launchd job

```bash
# Copy the plist to the LaunchAgents directory
cp com.openclaw.morning-briefing.plist \
   /Users/openclaw/Library/LaunchAgents/com.openclaw.morning-briefing.plist

# Load it (registers with launchd — will fire next time 8 AM arrives)
launchctl load -w \
  /Users/openclaw/Library/LaunchAgents/com.openclaw.morning-briefing.plist

# Verify it is loaded
launchctl list | grep morning-briefing
```

You should see a line like:
```
-   0   com.openclaw.morning-briefing
```

The `-` in the first column means it is not currently running (correct — it only runs at 8 AM).

---

## Verifying the schedule

To confirm it will fire at the right time:

```bash
# Check timezone
sudo systemsetup -gettimezone
# Should say: Asia/Tokyo

# Force a test run right now (optional)
launchctl start com.openclaw.morning-briefing

# Watch the log in real time
tail -f /Users/openclaw/.openclaw/logs/morning-briefing.log
```

---

## If you need to stop it

```bash
launchctl unload -w \
  /Users/openclaw/Library/LaunchAgents/com.openclaw.morning-briefing.plist
```

---

## Troubleshooting

| Symptom | Fix |
|---|---|
| No messages posted, log says `ERROR: WEBHOOK_URL not set` | Edit `briefing.sh` and replace the placeholder with your actual webhook URL |
| No messages posted, log says `curl/parse failed` | Check internet. Run `curl -fsSL https://feeds.bbci.co.uk/news/rss.xml` manually |
| Job doesn't run at 8 AM | Confirm Mac timezone is Asia/Tokyo. Confirm plist is loaded: `launchctl list | grep morning-briefing` |
| python3 not found | Run `which python3`. If missing: `brew install python3` |
| Messages show in Discord but links aren't clickable | Discord is suppressing embeds — check channel settings. The `[text](url)` format is correct markdown |

---

## Why this bypasses OpenClaw's announce summarization

The script produces **no stdout** (all output goes to the log file). Even if OpenClaw's cron triggers it via an isolated agent with `announce` delivery, there is nothing for the agent to summarize — the script has already posted directly to Discord before the agent can say anything.

---

## Alternative delivery: OpenClaw local HTTP API (no webhook URL needed)

OpenClaw exposes a local HTTP API on `http://localhost:18789`. You can use this instead of a Discord webhook — messages are sent over the existing bot connection, so no webhook setup is needed.

To switch to this method, replace the `post_to_discord()` function in `briefing.sh` with:

```bash
OPENCLAW_CHANNEL="channel:1488911439912636428"   # your #briefing channel ID

post_to_discord() {
  local content="$1"

  local payload
  payload=$(python3 -c "
import json, sys
print(json.dumps({
  'tool': 'agent_send',
  'input': {
    'channel': sys.argv[1],
    'message': sys.argv[2]
  }
}))
" "$OPENCLAW_CHANNEL" "$content")

  curl -fsSL -X POST \
    -H "Content-Type: application/json" \
    -d "$payload" \
    "http://localhost:18789/tools/invoke"
}
```

**Prerequisites for the local API approach:**
- The OpenClaw gateway daemon must be running: `openclaw gateway status`
- The `channels.discord.token` in `~/.openclaw/openclaw.json` must be a **plaintext string** (not a `SecretRef`) — there is a known bug ([openclaw/openclaw#33573](https://github.com/openclaw/openclaw/issues/33573)) where SecretRef tokens fail on outbound sends
- Channel `1488911439912636428` must be in your `guilds` allowlist in `openclaw.json`

The webhook approach (used by default in `briefing.sh`) requires no running daemon and has no known bugs, which is why it is the default here.
