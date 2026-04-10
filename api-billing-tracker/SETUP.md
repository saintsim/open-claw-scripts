# api-billing-tracker — Setup

Posts a daily Claude billing summary to Discord at 8 AM JST.

Sample output:
```
Claude bill update -

- API - $1.71 this month (+$0.45 in last 24h)
- Code - 20% remaining (til Sat 2pm)
```

## Prerequisites

- Mac Mini with timezone set to `Asia/Tokyo`
- `python3` on PATH (ships with macOS)
- `curl` on PATH (ships with macOS)
- Claude Code CLI (`claude`) installed and authenticated as the `openclaw` user
  (needed only for the "Code" metric — see Step 4)

---

## Step 1 — Create a Discord webhook

1. Open your Discord server → channel settings → Integrations → Webhooks → New Webhook
2. Copy the webhook URL

## Step 2 — Create an Anthropic admin API key

The cost report endpoint requires an **admin** key, not a regular API key.

1. Go to [platform.claude.com](https://platform.claude.com) → Settings → API Keys
2. Click **Create Key** → choose type **Admin** (prefix `sk-ant-admin…`)
3. Copy the key — you won't see it again

## Step 3 — Edit billing-tracker.sh

Replace the two placeholders near the top of the script:

```bash
ANTHROPIC_ADMIN_API_KEY="sk-ant-admin-..."          # your admin key
WEBHOOK_URL="https://discord.com/api/webhooks/..."  # your webhook
```

> **Never commit real values** — both are secrets. Keep the `REPLACE_WITH_`
> prefix on the placeholders in the repo copy.

## Step 4 — Claude Code plan usage (the "Code %" metric)

This metric makes a single 1-token call to `claude-haiku` (~$0.0000004) purely
to read the `anthropic-ratelimit-tokens-*` response headers. On a Max plan
these reflect the weekly token budget and include a reset timestamp, which
produces the "til Sat 2pm" portion of the output.

**No separate configuration is needed** if Claude Code is already set up for
the `openclaw` user. The script reads the stored OAuth access token from:

```
~/.claude/.credentials.json  →  claudeAiOauth.accessToken
```

If Claude Code is not yet authenticated for `openclaw`, run it once to log in:

```bash
# Log in as the openclaw user on the Mac Mini
claude
# Follow the OAuth prompt; credentials are saved automatically
```

If the credentials file is missing or the token is absent, the Code metric
will show `unavailable` in the Discord post — the API billing line is
unaffected.

### Why this approach (not a direct plan API)

Anthropic has no public endpoint for subscription plan usage percentage. The
rate-limit headers on any API response are the closest proxy available without
scraping the web UI. The script only treats the reset timestamp as meaningful
if it's more than one hour away (so minute-window rate limits are ignored).

---

## Step 5 — Deploy

```bash
DEPLOY_DIR="/Users/openclaw/.openclaw/workspace/api-billing-tracker"
mkdir -p "$DEPLOY_DIR"

cp billing-tracker.sh "$DEPLOY_DIR/"

cp com.openclaw.api-billing-tracker.plist \
   ~/Library/LaunchAgents/

launchctl load -w \
   ~/Library/LaunchAgents/com.openclaw.api-billing-tracker.plist
```

## Testing

Run directly:

```bash
bash /Users/openclaw/.openclaw/workspace/api-billing-tracker/billing-tracker.sh
```

Check the log:

```bash
cat ~/.openclaw/logs/api-billing-tracker.log
```

Trigger via launchd without waiting for 8 AM:

```bash
launchctl start com.openclaw.api-billing-tracker
```

---

## Troubleshooting

| Symptom | Fix |
|---|---|
| `cost_report request failed` | Check admin API key; regular keys return 403 |
| `API cost this month: $0.00` | Check log for raw JSON — field names may differ; adjust python3 parsing in script |
| `Code - unavailable` | Run `claude` once as `openclaw` user to authenticate |
| `accessToken missing` | Token may have expired; re-authenticate with `claude` |
| No Discord message | Check `~/.openclaw/logs/api-billing-tracker.log` for errors |

## Intel Mac note

Replace `/opt/homebrew/bin` with `/usr/local/bin` in the plist `PATH` if
deploying to an Intel Mac Mini.
