#!/usr/bin/env bash
# poll-and-save-max.sh
set -Eeuo pipefail

SCRIPT_NAME="$(basename "$0")"

# optional environment
DB_DIR="${DB_DIR:-./db}"
VERBOSE="${VERBOSE:-0}"

MAX_DIR="$DB_DIR/max"
MARKER_FILE="$MAX_DIR/marker.txt"
POLL_MAX="$(dirname "${BASH_SOURCE[0]}")/poll-max.sh"

tmp=""

main() {
  handle_help "$@"
  [[ $# -eq 0 ]] || error 2 "Unexpected arguments"

  mkdir -p "$MAX_DIR/users"
  trap cleanup EXIT

  local marker="" response new_marker updates
  [[ ! -f "$MARKER_FILE" ]] || marker=$(<"$MARKER_FILE")

  response=$("$POLL_MAX" ${marker:+"$marker"})
  new_marker=$(jq -r '.marker // empty' <<< "$response")

  # Sort before updating each user's last_seq.
  updates=$(jq -c '
    [.updates[]
      | select(.update_type == "message_created")
      | select(.message.sender.user_id != null)
      | select(.message.body.seq != null)
    ]
    | sort_by(.message.sender.user_id, .message.body.seq)
    | .[]
  ' <<< "$response")

  local update user_id seq user_dir last_seq inbox

  while IFS= read -r update; do
    [[ -n "$update" ]] || continue

    user_id=$(jq -r '.message.sender.user_id' <<< "$update")
    seq=$(jq -r '.message.body.seq' <<< "$update")

    [[ "$user_id" =~ ^[0-9]+$ && "$seq" =~ ^[0-9]+$ ]] \
      || error 65 "Invalid user_id or seq"

    user_dir="$MAX_DIR/users/$user_id"
    inbox="$user_dir/inbox"
    mkdir -p "$inbox"

    last_seq=0
    [[ ! -f "$user_dir/last_seq.txt" ]] \
      || last_seq=$(<"$user_dir/last_seq.txt")

    (( 10#$seq > 10#$last_seq )) || continue

    tmp=$(mktemp "$inbox/.message.XXXXXX")
    printf '%s\n' "$update" > "$tmp"
    mv "$tmp" "$inbox/$seq.json"
    tmp=""

    tmp=$(mktemp "$user_dir/.last_seq.XXXXXX")
    printf '%s\n' "$seq" > "$tmp"
    mv "$tmp" "$user_dir/last_seq.txt"
    tmp=""

    [[ "$VERBOSE" == "1" ]] && log "Saved user=$user_id seq=$seq"
  done <<< "$updates"

  if [[ -n "$new_marker" ]]; then
    tmp=$(mktemp "$MAX_DIR/.marker.XXXXXX")
    printf '%s\n' "$new_marker" > "$tmp"
    mv "$tmp" "$MARKER_FILE"
    tmp=""
  fi

  if [[ "$VERBOSE" == "1" ]]; then
    log "Polling completed: marker=${new_marker:-none}"
  fi
}

usage() {
  cat <<EOF_USAGE
$SCRIPT_NAME — poll MAX once and save raw messages.

Usage:
  $SCRIPT_NAME
  $SCRIPT_NAME -h|--help

Environment:
  DB_DIR            Database directory (default: ./db).
  MAX_BOT_TOKEN     Required by poll-max.sh.
  MAX_POLL_TIMEOUT  Polling timeout (default: 30).
  VERBOSE           Enable diagnostic logs (default: 0).

Files:
  max/marker.txt                     Global polling cursor.
  max/users/<id>/last_seq.txt        Last saved message sequence.
  max/users/<id>/inbox/<seq>.json     Raw MAX update.

Exit codes:
  0    Success.
  2    Invalid arguments.
  65   Invalid message data.
  Other errors are propagated from commands and poll-max.sh.

Example:
  $SCRIPT_NAME
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

cleanup() {
  [[ -z "$tmp" ]] || rm -f -- "$tmp"
}

# endregion

main "$@"
