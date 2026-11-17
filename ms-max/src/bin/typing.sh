#!/usr/bin/env bash
# typing.sh
set -euo pipefail

# required environment
: "${MAX_BOT_TOKEN:?}"

# optional environment
MAX_API_URL="${MAX_API_URL:-https://platform-api2.max.ru}"

main() {
  [[ $# -eq 1 && "$1" =~ ^-?[0-9]+$ ]] || { echo "Expected chat_id" >&2; return 2; }

  curl -fsS --connect-timeout 5 --max-time 10 \
    -X POST "${MAX_API_URL%/}/chats/$1/actions" \
    -H "Authorization: $MAX_BOT_TOKEN" \
    -H 'Content-Type: application/json' \
    -d '{"action":"typing_on"}' | jq -e '.success == true' >/dev/null
}

main "$@"
