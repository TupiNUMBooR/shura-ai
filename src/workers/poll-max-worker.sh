#!/usr/bin/env bash
# poll-max-worker.sh
set -Eeuo pipefail

SCRIPT_NAME="$(basename "$0")"

# optional environment
POLL_AND_SAVE_MAX="${POLL_AND_SAVE_MAX:-$(dirname "${BASH_SOURCE[0]}")/../bin/poll-and-save-max.sh}"
VERBOSE="${VERBOSE:-0}"

main() {
  handle_help "$@"
  [[ $# -eq 0 ]] || error 2 "Unexpected arguments"

  while true; do
    "$POLL_AND_SAVE_MAX"
  done
}

usage() {
  cat <<EOF_USAGE
$SCRIPT_NAME — continuously poll MAX and save incoming messages.

Usage:
  $SCRIPT_NAME
  $SCRIPT_NAME -h|--help

Environment:
  POLL_AND_SAVE_MAX  Polling brick (default: ../bin/poll-and-save-max.sh).
  DB_DIR             Database directory (default: ./db).
  MAX_BOT_TOKEN      Required by poll-max.sh.
  MAX_POLL_TIMEOUT   Polling timeout (default: 30).
  VERBOSE            Enable diagnostic logs (default: 0).

Exit codes:
  0    Help displayed.
  2    Invalid arguments.
  Other errors are propagated from poll-and-save-max.sh.
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
