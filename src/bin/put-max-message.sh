#!/usr/bin/env bash
# put-max-message.sh
set -Eeuo pipefail

SCRIPT_NAME="$(basename "$0")"

# required environment
MAX_BOT_TOKEN="${MAX_BOT_TOKEN:-}"

# optional environment
MAX_API_URL="${MAX_API_URL:-https://platform-api2.max.ru}"
VERBOSE="${VERBOSE:-0}"

main() {
  handle_help "$@"

  [[ $# -eq 1 ]] || error 2 "Expected message mid"
  [[ -n "$MAX_BOT_TOKEN" ]] || error 78 "MAX_BOT_TOKEN is required"
  local mid="$1"
  [[ "$mid" =~ ^[a-zA-Z0-9_.-]+$ ]] || error 2 "Invalid message mid"

  local payload
  payload=$(jq -Rs 'sub("\n$"; "") | if length > 0 and length <= 4000 then {text: .} else error("Text must contain 1..4000 characters") end') \
    || error 65 "Invalid message text"

  local response status http_code
  response=$(mktemp) || error 73 "Cannot create temporary file"
  trap '[[ -z "${response:-}" ]] || rm -f "$response"' EXIT

  [[ "$VERBOSE" == 1 ]] && log "PUT /messages?message_id=$mid" || true

  if http_code=$(curl --silent --show-error \
      --connect-timeout 10 --max-time 60 \
      --output "$response" --write-out '%{http_code}' \
      --request PUT \
      --header "Authorization: $MAX_BOT_TOKEN" \
      --header 'Content-Type: application/json' \
      --data-binary "$payload" \
      "${MAX_API_URL%/}/messages?message_id=$mid"); then
    :
  else
    status=$?
    case "$status" in
      28) error 75 "MAX request timed out; message may have been edited" ;;
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

  if ! jq -e '.success == true' "$response" >/dev/null 2>&1; then
    local details
    details=$(jq -c '{success, code, message}' "$response" 2>/dev/null || cat "$response")
    error 65 "MAX edit failed: $details"
  fi
}

usage() {
  cat <<EOF_USAGE
$SCRIPT_NAME — edit an existing MAX text message.

Usage:
  echo "Updated text" | $SCRIPT_NAME 'mid.abc123'
  $SCRIPT_NAME -h|--help

Arguments:
  mid            Message ID returned by post-max-message.sh.

Input:
  stdin          Replacement text (1..4000 characters).
                 One final newline is removed (convenient for echo).

Output:
  stdout         Empty on success or failure.
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
  75   Temporary HTTP failure or timeout.
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
