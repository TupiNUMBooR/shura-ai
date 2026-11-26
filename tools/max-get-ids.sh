#!/usr/bin/env bash
# max-get-ids.sh
set -euo pipefail

if [[ "${1:-}" == --help || "${1:-}" == -h ]]; then
  cat -- "${BASH_SOURCE[0]}"
  exit
fi

source ./.env
MAX_API_URL="${MAX_API_URL:-https://platform-api2.max.ru}"

[[ $# -eq 0 ]] || { echo "Unexpected arguments" >&2; exit 2; }
: "${MAX_BOT_TOKEN:?}"
command -v jq >/dev/null || { echo "jq is required" >&2; exit 69; }

response=$(mktemp)
trap '[[ -z "${response:-}" ]] || rm -f "$response"' EXIT

code=$(curl --silent --show-error \
  --connect-timeout 10 --max-time 45 \
  --output "$response" --write-out '%{http_code}' \
  --header "Authorization: $MAX_BOT_TOKEN" \
  "${MAX_API_URL%/}/updates?timeout=30&limit=100") || exit 69

[[ "$code" == 200 ]] || {
  echo "HTTP $code: $(<"$response")" >&2
  exit 65
}

jq -r '
  [.updates[]? |
    {
      event: .update_type,
      user_id: (.callback.user.user_id // .message.sender.user_id // .user.user_id // null),
      chat_id: (.message.recipient.chat_id // .chat_id // .chat.chat_id // null)
    }
    | select(.user_id != null or .chat_id != null)
  ] | unique | .[] |
  "\(.event)  user_id=\(.user_id // "-")  chat_id=\(.chat_id // "-")"
' "$response"
