#!/usr/bin/env bash
# get-max-ids.sh
set -euo pipefail

SCRIPT_NAME="$(basename "$0")"

# required environment
: "${MAX_BOT_TOKEN:?MAX_BOT_TOKEN is required}"

# optional environment
MAX_API_URL="${MAX_API_URL:-https://platform-api2.max.ru}"

main() {
  [[ $# -eq 0 ]] || { echo "Unexpected arguments" >&2; return 2; }

  local response code
  response=$(mktemp)
  trap '[[ -z "${response:-}" ]] || rm -f "$response"' EXIT

  code=$(curl --silent --show-error \
    --connect-timeout 10 --max-time 45 \
    --output "$response" --write-out '%{http_code}' \
    --header "Authorization: $MAX_BOT_TOKEN" \
    "${MAX_API_URL%/}/updates?timeout=30&limit=100") || return 69

  [[ "$code" == 200 ]] || {
    printf '[%s] HTTP %s: %s\n' "$SCRIPT_NAME" "$code" "$(cat "$response")" >&2
    return 65
  }

  jq -r '
    [.updates[]? |
      {
        event: .update_type,
        user_id: (.message.sender.user_id // .user.user_id // .callback.user.user_id // null),
        chat_id: (.message.recipient.chat_id // .chat_id // .chat.chat_id // null)
      }
      | select(.user_id != null or .chat_id != null)
    ] | unique | .[] |
    "\(.event)  user_id=\(.user_id // "-")  chat_id=\(.chat_id // "-")"
  ' "$response"
}

main "$@"
