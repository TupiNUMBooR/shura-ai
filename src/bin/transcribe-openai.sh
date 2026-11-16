#!/usr/bin/env bash
# transcribe-openai.sh
set -Eeuo pipefail

SCRIPT_NAME="$(basename "$0")"

# required environment
OPENAI_API_KEY="${OPENAI_API_KEY:-}"

# optional environment
OPENAI_ENDPOINT_URL="${OPENAI_ENDPOINT_URL:-https://api.openai.com/v1/audio/transcriptions}"
OPENAI_TRANSCRIBE_MODEL="${OPENAI_TRANSCRIBE_MODEL:-gpt-transcribe}"
VERBOSE="${VERBOSE:-0}"

main() {
  handle_help "$@"

  [[ $# -eq 1 ]] || error 2 "Expected audio file"
  [[ -n "$OPENAI_API_KEY" ]] || error 78 "OPENAI_API_KEY is required"
  [[ -f "$1" && -r "$1" ]] || error 66 "Cannot read audio file: $1"

  local audio_file="$1"
  local response

  if [[ "$VERBOSE" == "1" ]]; then
    log "transcribe: file=$audio_file model=$OPENAI_TRANSCRIBE_MODEL"
  fi

  response="$(curl -fsS "$OPENAI_ENDPOINT_URL" \
    -H "Authorization: Bearer $OPENAI_API_KEY" \
    -F "file=@$audio_file" \
    -F "model=$OPENAI_TRANSCRIBE_MODEL" \
    -F "response_format=json")" || error 69 "Transcription request failed"

  jq -e '.text | strings' <<< "$response" >/dev/null \
    || error 65 "Invalid transcription response"

  printf '%s\n' "$response"
}

usage() {
  cat <<EOF_USAGE
$SCRIPT_NAME — transcribe audio to text using OpenAI.

Usage:
  $SCRIPT_NAME <audio_file>
  $SCRIPT_NAME -h|--help

Arguments:
  audio_file             Path to audio file.

Environment:
  OPENAI_API_KEY          Required.
  OPENAI_ENDPOINT_URL     OpenAI transcription endpoint.
  OPENAI_TRANSCRIBE_MODEL Model (default: gpt-transcribe).
  VERBOSE                 Log details when set to 1 (default: 0).

Exit codes:
  0    Success.
  2    Invalid arguments.
  65   Invalid API response.
  66   Audio file cannot be read.
  69   Transcription request failed.
  78   Configuration error.

Example:
  $SCRIPT_NAME voice.ogg
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

warn() {
  log "[WARN] $*"
}

error() {
  local code="$1"
  shift

  log "[ERROR] $*"
  exit "$code"
}

# endregion

main "$@"
