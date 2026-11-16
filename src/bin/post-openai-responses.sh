#!/usr/bin/env bash
# post-openai-responses.sh
set -Eeuo pipefail

SCRIPT_NAME="$(basename "$0")"

# required environment
OPENAI_API_KEY="${OPENAI_API_KEY:-}"

# optional environment
OPENAI_ENDPOINT_URL="${OPENAI_ENDPOINT_URL:-https://api.openai.com/v1/responses}"
VERBOSE="${VERBOSE:-0}"

main() {
  handle_help "$@"

  [[ $# -eq 0 ]] || error 2 "Unexpected arguments"
  [[ -n "$OPENAI_API_KEY" ]] || error 78 "OPENAI_API_KEY is required"
  local request
  request="$(cat)"
  [[ -n "${request//[[:space:]]/}" ]] || error 66 "Request is empty"
  jq -e 'type == "object" and (.model | type == "string" and length > 0)' \
    <<< "$request" >/dev/null 2>&1 || error 65 "Invalid Responses API request JSON"

  local response http_code
  response="$(mktemp)" || error 73 "Cannot create temporary response file"
  trap "rm -f -- '$response'" EXIT

  [[ "$VERBOSE" == "1" ]] && log "POST $OPENAI_ENDPOINT_URL"

  http_code="$(
    printf '%s' "$request" | curl -sS \
      -o "$response" -w '%{http_code}' \
      -H "Authorization: Bearer $OPENAI_API_KEY" \
      -H 'Content-Type: application/json' \
      --data-binary @- "$OPENAI_ENDPOINT_URL"
  )" || error 13 "OpenAI request failed"

  if [[ ! "$http_code" =~ ^2[0-9][0-9]$ ]]; then
    cat "$response" >&2
    error 13 "OpenAI API returned HTTP $http_code"
  fi

  jq -e 'if type == "object" and .error == null then . else error("Invalid response") end' "$response" \
    || error 13 "Invalid OpenAI API response"
}

usage() {
  cat <<EOF_USAGE
$SCRIPT_NAME — POST a JSON request to the OpenAI Responses API.

Usage:
  $SCRIPT_NAME < request.json > response.json
  $SCRIPT_NAME -h|--help

Input:
  stdin               Ready Responses API request JSON (must contain model).

Output:
  stdout              Raw JSON response, only on success.
  stderr              Logs and errors.

Environment:
  OPENAI_API_KEY       Required API key.
  OPENAI_ENDPOINT_URL  API endpoint (default: https://api.openai.com/v1/responses).
  VERBOSE              Log the request endpoint when set to 1 (default: 0).

Exit codes:
  0    Success.
  2    Invalid arguments.
  65   Invalid request JSON.
  66   Empty input.
  73   Cannot create temporary file.
  78   Missing API key.

  13   API request or response failed (possibly billed).
EOF_USAGE
}

# region functions

handle_help() {
  if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    [[ $# -eq 1 ]] || error 2 "Unexpected arguments after $1"
    usage
    exit 0
  fi
}

log() {
  printf '[%s] [%s] %s\n' \
    "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$SCRIPT_NAME" "$*" >&2
}

error() {
  local code="$1"
  shift
  log "[ERROR] $*"
  exit "$code"
}

# endregion

main "$@"
