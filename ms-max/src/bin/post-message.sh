#!/usr/bin/env bash
# post-message.sh
set -Eeuo pipefail

SCRIPT_NAME="$(basename "$0")"

# required environment
MAX_BOT_TOKEN="${MAX_BOT_TOKEN:-}"

# optional environment
MAX_API_URL="${MAX_API_URL:-https://platform-api2.max.ru}"
VERBOSE="${VERBOSE:-0}"

main() {
  handle_help "$@"

  [[ $# -eq 1 ]] || error 2 "Expected chat_id"
  [[ -n "$MAX_BOT_TOKEN" ]] || error 78 "MAX_BOT_TOKEN is required"
  local chat_id="$1"
  [[ "$chat_id" =~ ^-?[0-9]+$ ]] || error 2 "Invalid chat_id"

  local payload
  payload=$(jq -Rs 'sub("\n$"; "") | if length > 0 and length <= 4000 then {text: .} else error("Text must contain 1..4000 characters") end') \
    || error 65 "Invalid message text"

  local response status http_code mid
  response=$(mktemp) || error 73 "Cannot create temporary file"
  trap '[[ -z "${response:-}" ]] || rm -f "$response"' EXIT

  [[ "$VERBOSE" == 1 ]] && log "POST /messages?chat_id=$chat_id" || true

  if http_code=$(curl --silent --show-error \
      --connect-timeout 10 --max-time 60 \
      --output "$response" --write-out '%{http_code}' \
      --request POST \
      --header "Authorization: $MAX_BOT_TOKEN" \
      --header 'Content-Type: application/json' \
      --data-binary "$payload" \
      "${MAX_API_URL%/}/messages?chat_id=$chat_id"); then
    :
  else
    status=$?
    case "$status" in
      28) error 75 "MAX request timed out; message may have been sent" ;;
      *)  error 69 "MAX request failed (curl exit $status)" ;;
    esac
  fi

  if [[ "$http_code" != 200 ]]; then
    local details
    details=$(jq -c '.' "$response" 2>/dev/null || cat "$response")
    case "$http_code" in
      401) error 78 "MAX HTTP $http_code: $details" ;;
      408|429|5??) error 75 "MAX HTTP $http_code: $details" ;;
      *) error 65 "MAX HTTP $http_code: $details" ;;
    esac
  fi

  mid=$(jq -er '.message.body.mid | select(type == "string" and length > 0)' "$response" 2>/dev/null) \
    || error 65 "MAX returned no message.body.mid"
  printf '%s\n' "$mid"
}

usage() {
  cat <<EOF_USAGE
$SCRIPT_NAME — send a text message through MAX API, print only its mid.

Usage:
  echo "Hello" | $SCRIPT_NAME -81322498078826
  $SCRIPT_NAME -h|--help

Arguments:
  chat_id        Numeric MAX chat ID (may be negative).

Input:
  stdin          Text to send (1..4000 characters).
                 One final newline is removed (convenient for echo).

Output:
  stdout         Message mid on success; empty on failure.
  stderr         Diagnostics and optional verbose logging.

Environment:
  MAX_BOT_TOKEN  Required API token.
  MAX_API_URL    Default: https://platform-api2.max.ru
  VERBOSE        Set to 1 for request logging (default: 0).

Exit codes:
  0    Success.
  2    Invalid arguments.
  65   Invalid text, API response, or non-retryable HTTP error.
  69   Network/curl failure.
  73   Cannot create temporary file.
  75   Temporary HTTP failure or timeout (retry may duplicate a message).
  78   Missing/invalid token.
EOF_USAGE
}

# region functions

handle_help() {
  if [[ "${1:-}" == -h || "${1:-}" == --help ]]; then
    usage
    exit 0
  fi
}

log() {
  printf '[%s] [%s] %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$SCRIPT_NAME" "$*" >&2
}

error() {
  local code="$1"
  shift
  log "[ERROR] $*"
  exit "$code"
}

# endregion

main "$@"
