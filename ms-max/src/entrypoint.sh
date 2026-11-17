#!/usr/bin/env bash
# entrypoint.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_NAME="$(basename "$0")"
VERSION="${VERSION:-dev}"

pids=()

cleanup() {
  trap - TERM INT EXIT
  log "Stopped VERSION=$VERSION"
  kill "${pids[@]}" 2>/dev/null || :
  wait 2>/dev/null || :
}

trap cleanup EXIT
trap 'exit 0' TERM INT

log() { printf '[%s] [%s] %s\n' "$(date -u +%FT%TZ)" "$SCRIPT_NAME" "$*" >&2; }

worker() {
  while true; do
    "$1" || exit 1
  done
}

worker "$SCRIPT_DIR/bin/receive-messages.sh" &
pids+=("$!")

worker "$SCRIPT_DIR/bin/send-messages.sh" &
pids+=("$!")

log "Started VERSION=$VERSION"

wait -n "${pids[@]}" || :
exit 1
