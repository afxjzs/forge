#!/usr/bin/env bash
set -euo pipefail

# forge-notify.sh — Send notification via the forge bot
#
# Usage: forge-notify.sh "message text"
#        forge-notify.sh --file /path/to/message.txt
#
# Routes through the forge bot's HTTP endpoint (port 8774).
# Falls back to direct Telegram API if the bot is down.

FORGE_ROOT="${FORGE_ROOT:-$HOME/nexus/infra/dev-pipeline}"
[[ -f "$FORGE_ROOT/.env" ]] && set -a && source "$FORGE_ROOT/.env" && set +a

FORGE_BOT_NOTIFY="http://127.0.0.1:${FORGE_NOTIFY_PORT:-8774}/notify"
# Fallback: direct Telegram API (env vars from .env, or token file)
FALLBACK_BOT_TOKEN="${FORGE_BOT_TOKEN:-$(cat "$HOME/.forge-bot-token" 2>/dev/null || echo "")}"
FALLBACK_CHAT_ID="${FORGE_CHAT_ID:-}"

if [[ -z "$FALLBACK_CHAT_ID" ]]; then
    echo "ERROR: FORGE_CHAT_ID not set. Cannot send notifications." >&2
    exit 1
fi

[[ $# -lt 1 ]] && { echo "Usage: forge-notify.sh \"message\""; exit 1; }

MESSAGE=""
if [[ "$1" == "--file" ]]; then
    [[ $# -lt 2 ]] && { echo "Usage: forge-notify.sh --file path"; exit 1; }
    MESSAGE=$(cat "$2")
else
    MESSAGE="$1"
fi

[[ -z "$MESSAGE" ]] && { echo "Empty message, skipping."; exit 0; }

# Escape message for JSON
JSON_MESSAGE=$(python3 -c "import json,sys; print(json.dumps(sys.argv[1]))" "$MESSAGE") || {
    echo "WARNING: JSON escaping failed, using raw message" >&2
    JSON_MESSAGE="\"$MESSAGE\""
}

# Try the bot endpoint first
CURL_ERR=$(mktemp)
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 \
    -X POST "$FORGE_BOT_NOTIFY" \
    -H "Content-Type: application/json" \
    -d "{\"message\": $JSON_MESSAGE}" \
    2>"$CURL_ERR" || echo "000")
[[ -s "$CURL_ERR" ]] && echo "Notify curl error: $(cat "$CURL_ERR")" >&2
rm -f "$CURL_ERR"

if [[ "$HTTP_CODE" == "200" ]]; then
    echo "Notification sent via forge bot."
    exit 0
fi

# Fallback: direct Telegram API with forge bot token
if [[ -n "$FALLBACK_BOT_TOKEN" ]]; then
    echo "Forge bot unavailable (HTTP $HTTP_CODE). Falling back to direct Telegram API..." >&2
    CURL_ERR=$(mktemp)
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 \
        -X POST "https://api.telegram.org/bot${FALLBACK_BOT_TOKEN}/sendMessage" \
        -d chat_id="$FALLBACK_CHAT_ID" \
        --data-urlencode text="$MESSAGE" \
        2>"$CURL_ERR" || echo "000")
    [[ -s "$CURL_ERR" ]] && echo "Telegram API curl error: $(cat "$CURL_ERR")" >&2
    rm -f "$CURL_ERR"

    if [[ "$HTTP_CODE" == "200" ]]; then
        echo "Notification sent via direct Telegram API (fallback)."
        exit 0
    fi
fi

echo "ERROR: All notification methods failed (HTTP $HTTP_CODE)." >&2
exit 1
