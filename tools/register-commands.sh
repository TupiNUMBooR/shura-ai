
#!/usr/bin/env bash
# register-commands.sh
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
  trap "rm -f '$response'" EXIT

  code=$(curl --silent --show-error \
    --connect-timeout 10 --max-time 45 \
    --output "$response" --write-out '%{http_code}' \
    --request PATCH \
    --header "Authorization: $MAX_BOT_TOKEN" \
    --header 'Content-Type: application/json' \
    --data '{
      "commands": [
        {
          "name": "start",
          "description": "Начать работу"
        },
        {
          "name": "help",
          "description": "Справка"
        },
        {
          "name": "buy",
          "description": "Купить кредиты"
        }
      ]
    }' \
    "${MAX_API_URL%/}/me/commands") || return 69

  if [[ "$code" != 200 ]]; then
    printf 'MAX HTTP %s: %s\n' "$code" "$(cat "$response")" >&2
    return 1
  fi

  echo 'Commands registered: /start /help /buy'
}

main "$@"
