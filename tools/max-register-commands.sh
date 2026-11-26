#!/usr/bin/env bash
# max-register-commands.sh
set -euo pipefail

if [[ "${1:-}" == --help || "${1:-}" == -h ]]; then
  cat -- "${BASH_SOURCE[0]}"
  exit
fi

source ./.env
MAX_API_URL="${MAX_API_URL:-https://platform-api2.max.ru}"
data='{
  "commands": [
    {"name": "start",   "description": "Начать работу"},
    {"name": "help",    "description": "Справка"},
    {"name": "buy",     "description": "Купить кредиты"},
    {"name": "balance", "description": "Мой баланс"},
    {"name": "reset",   "description": "Начать новый диалог"},
    {"name": "support", "description": "Обращение в поддержку"}
  ]
}'

[[ $# -eq 0 ]] || { echo "Unexpected arguments" >&2; exit 2; }
: "${MAX_BOT_TOKEN:?}"
command -v jq >/dev/null || { echo "jq is required" >&2; exit 69; }

response=$(mktemp)
trap 'rm -f "$response"' EXIT

code=$(curl --silent --show-error --connect-timeout 10 --max-time 45 \
  --output "$response" --write-out '%{http_code}' --request PATCH \
  --header "Authorization: $MAX_BOT_TOKEN" --header 'Content-Type: application/json' \
  --data "$data" \
  "${MAX_API_URL%/}/me/commands") || exit 69

[[ "$code" == 20[04] ]] || {
  echo "HTTP $code: $(<"$response")" >&2
  exit 65
}

jq -r '"Commands registered: " + ([.commands[].name | "/\(.)"] | join(" "))' <<< "$data"
