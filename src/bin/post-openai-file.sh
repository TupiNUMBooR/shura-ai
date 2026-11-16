#!/usr/bin/env bash
# post-openai-file.sh - Upload a vision file to OpenAI and print its JSON response.
set -euo pipefail

SCRIPT_NAME="$(basename "$0")"

# required environment
: "${OPENAI_API_KEY:?}"

# optional environment
OPENAI_ENDPOINT_URL="${OPENAI_ENDPOINT_URL:-https://api.openai.com/v1/files}"

main() {
  [[ $# -eq 1 ]] || error 2 "Expected file path"
  [[ -f "$1" && -r "$1" ]] || error 2 "Cannot read file: $1"

  log "Uploading file: $1"
  local response
  response="$(curl -sS --fail-with-body "$OPENAI_ENDPOINT_URL" \
    -H "Authorization: Bearer $OPENAI_API_KEY" \
    -F 'purpose=vision' \
    -F "file=@$1" \
    -F 'expires_after[anchor]=created_at' \
    -F 'expires_after[seconds]=2592000')" || error 1 "Upload failed: $response"

  jq -e '(.id | type == "string" and length > 0) and (.error == null)' \
    <<< "$response" >/dev/null || error 1 "Invalid upload response: $response"

  printf '%s\n' "$response"
}

# region functions

log()   { printf '[%s] [%s] %s\n' "$(date -u +%FT%TZ)" "$SCRIPT_NAME" "$*" >&2; }
warn()  { log "[WARN] $*"; }
error() { local code="$1"; shift; log "[ERROR] $*"; exit "$code"; }

# endregion

main "$@"
