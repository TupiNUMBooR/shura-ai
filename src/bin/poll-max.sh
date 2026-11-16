#!/usr/bin/env bash
# poll-max.sh
set -Eeuo pipefail

SCRIPT_NAME="$(basename "$0")"

# required environment
MAX_BOT_TOKEN="${MAX_BOT_TOKEN:-}"

# optional environment
MAX_ENDPOINT_URL="${MAX_ENDPOINT_URL:-https://platform-api2.max.ru/updates}"
MAX_POLL_TIMEOUT="${MAX_POLL_TIMEOUT:-30}"
VERBOSE="${VERBOSE:-0}"

main() {
  handle_help "$@"

  [[ $# -le 1 ]] || error 2 "Expected zero or one marker argument"
  [[ -n "$MAX_BOT_TOKEN" ]] || error 78 "MAX_BOT_TOKEN is required"
  [[ "$MAX_POLL_TIMEOUT" =~ ^([0-9]|[1-8][0-9]|90)$ ]] \
    || error 78 "MAX_POLL_TIMEOUT must be an integer from 0 to 90"

  local marker="${1:-}"
  [[ -z "$marker" || "$marker" =~ ^[0-9]+$ ]] \
    || error 2 "Marker must be a non-negative integer"

  local -a args=(
    --get --fail --silent --show-error
    --max-time "$((10#$MAX_POLL_TIMEOUT + 15))"
    --header "Authorization: $MAX_BOT_TOKEN"
    --data-urlencode "timeout=$MAX_POLL_TIMEOUT"
  )
  [[ -z "$marker" ]] || args+=(--data-urlencode "marker=$marker")

  [[ "$VERBOSE" == "1" ]] && log "Polling MAX: timeout=$MAX_POLL_TIMEOUT marker=${marker:-none}"

  local response
  response=$(curl "${args[@]}" "$MAX_ENDPOINT_URL") || error 69 "MAX API request failed"

  jq -e 'type == "object" and (.updates | type == "array") and (.marker | type == "number" or . == null)' \
    >/dev/null <<< "$response" || error 70 "Invalid MAX API response"

  printf '%s\n' "$response"
}

usage() {
  cat <<EOF_USAGE
$SCRIPT_NAME — fetch one batch of MAX updates via Long Polling.

Usage:
  $SCRIPT_NAME [marker]
  $SCRIPT_NAME -h|--help

Arguments:
  marker            Optional cursor from the previous response.

Environment:
  MAX_BOT_TOKEN     Required MAX bot token.
  MAX_ENDPOINT_URL  API endpoint (default: https://platform-api2.max.ru/updates).
  MAX_POLL_TIMEOUT  Polling timeout in seconds, 0-90 (default: 30).
  VERBOSE           Log request details when set to 1 (default: 0).

Output:
  stdout            Original JSON response: {"updates": [...], "marker": ...}.
  stderr            Diagnostics only.

Exit codes:
  0    Success (including empty updates).
  2    Invalid arguments.
  69   Network or HTTP error.
  70   Invalid API response.
  78   Configuration error.

Example:
  $SCRIPT_NAME
  $SCRIPT_NAME 123456789
EOF_USAGE
}

# region functions

handle_help() {
  if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
  fi
}

log() {
  printf '[%s] [%s] %s\n' \
    "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
    "$SCRIPT_NAME" \
    "$*" >&2
}

error() {
  local code="$1"
  shift
  log "[ERROR] $*"
  exit "$code"
}

# endregion

main "$@"
