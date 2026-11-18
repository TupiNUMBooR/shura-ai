#!/usr/bin/env bash
# entrypoint.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_NAME="$(basename "$0")"
VERSION="${VERSION:-dev}"
pids=()

log() { printf '[%s] [%s] %s\n' "$(date -u +%FT%TZ)" "$SCRIPT_NAME" "$*" >&2; }
cleanup() {
  trap - TERM INT EXIT
  log "Stopped VERSION=$VERSION"
  kill "${pids[@]}" 2>/dev/null || :
  wait 2>/dev/null || :
}
trap cleanup EXIT
trap 'exit 0' TERM INT

worker() {
  local script="$1" interval="$2"
  while true; do
    "$script" || log "[WARN] Worker failed: ${script##*/}"
    sleep "$interval"
  done
}

worker "$SCRIPT_DIR/bin/process-orders.sh" 1 &
pids+=("$!")
worker "$SCRIPT_DIR/bin/poll-payments.sh" 10 &
pids+=("$!")
log "Started VERSION=$VERSION"
wait -n "${pids[@]}" || :
exit 1
