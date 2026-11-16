#!/usr/bin/env bash
# post-openai-file.sh
set -Eeuo pipefail

SCRIPT_NAME="${0##*/}"
OPENAI_API_KEY="${OPENAI_API_KEY:-}"
OPENAI_ENDPOINT_URL="${OPENAI_ENDPOINT_URL:-https://api.openai.com/v1/files}"

usage() {
  cat <<EOF_USAGE
$SCRIPT_NAME — upload a file to OpenAI Files API and print the raw JSON response.

Usage:
  $SCRIPT_NAME <file>
  $SCRIPT_NAME -h|--help

Input:
  file             Local file to upload (purpose=vision).

Environment:
  OPENAI_API_KEY   Required API key.
  OPENAI_ENDPOINT_URL  Optional endpoint (default: https://api.openai.com/v1/files).

Output:
  stdout           Raw JSON response on success.
  stderr           Diagnostics and API errors.

Exit codes:
  0    Success.
  2    Invalid arguments.
  65   Invalid API response.
  66   Input file missing or unreadable.
  69   Upload failed or API unavailable.
  78   Missing API key.

Example:
  $SCRIPT_NAME image.png > upload.json
EOF_USAGE
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

main() {
  if [[ "${1:-}" == '-h' || "${1:-}" == '--help' ]]; then
    (($# == 1)) || error 2 'Help accepts no additional arguments'
    usage
    return 0
  fi

  (($# == 1)) || error 2 'Expected exactly one file path'
  [[ -n "$OPENAI_API_KEY" ]] || error 78 'OPENAI_API_KEY is required'
  [[ -f "$1" && -r "$1" ]] || error 66 "File missing or unreadable: $1"
  local response http_code
  response="$(mktemp)" || error 73 'Cannot create temporary file'
  trap "rm -f -- '$response'" EXIT

  # curl writes the response body to a temporary file; stdout remains JSON-only.
  if ! http_code="$(curl -sS -o "$response" -w '%{http_code}' \
    -H "Authorization: Bearer $OPENAI_API_KEY" \
    -F 'purpose=vision' \
    -F "file=@$1" \
    -F 'expires_after[anchor]=created_at' \
    -F 'expires_after[seconds]=2592000' \
    "$OPENAI_ENDPOINT_URL")"; then
    [[ ! -s "$response" ]] || cat "$response" >&2
    error 69 'Upload failed'
  fi

  if [[ ! "$http_code" =~ ^2[0-9][0-9]$ ]]; then
    [[ ! -s "$response" ]] || cat "$response" >&2
    error 69 "HTTP $http_code"
  fi

  if ! jq -e 'type == "object" and (.id | type == "string" and length > 0) and (.error == null)' "$response" >/dev/null; then
    cat "$response" >&2
    error 65 'Invalid upload response'
  fi

  cat "$response"
}

main "$@"
