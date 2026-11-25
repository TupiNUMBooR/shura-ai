#!/usr/bin/env bash
# answer-callback.sh - Send a MAX callback notification from stdin.
set -euo pipefail

SCRIPT_NAME="$(basename "$0")"

# required environment
MAX_BOT_TOKEN="${MAX_BOT_TOKEN:-}"

# optional environment
MAX_API_URL="${MAX_API_URL:-https://platform-api2.max.ru}"

response_file=""

main() {
  [[ $# -eq 1 && "$1" =~ [^[:space:]] ]] || error 2 'Expected callback_id'
  [[ -n "$MAX_BOT_TOKEN" ]] || error 78 'MAX_BOT_TOKEN is required'

  local callback_id body http_code
  callback_id=$(jq -nr --arg id "$1" '$id | @uri')
  body=$(jq -eRs 'sub("\n$"; "") | select(test("\\S")) | {notification: .}') \
    || error 65 'Expected notification text'

  response_file=$(mktemp) || error 73 'Cannot create temporary file'
  trap 'rm -f -- "$response_file"' EXIT
  http_code=$(curl --silent --show-error --connect-timeout 5 --max-time 15 \
    --output "$response_file" --write-out '%{http_code}' \
    --request POST --header "Authorization: $MAX_BOT_TOKEN" --header 'Content-Type: application/json' \
    --data-binary "$body" \
    "${MAX_API_URL%/}/answers?callback_id=$callback_id") || error 69 'MAX callback request failed'

  [[ "$http_code" == 200 || "$http_code" == 204 ]] \
    || error 65 "MAX callback HTTP $http_code: $(cat "$response_file")"
}

# region functions

log()   { printf '[%s] [%s] %s\n' "$(date -u +%FT%TZ)" "$SCRIPT_NAME" "$*" >&2; }
error() { local code="$1"; shift; log "[ERROR] $*"; exit "$code"; }

# endregion

main "$@"
