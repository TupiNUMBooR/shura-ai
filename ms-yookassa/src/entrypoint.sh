#!/usr/bin/env bash
# entrypoint.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_NAME="$(basename "$0")"
VERSION="${VERSION:-dev}"
RECEIPT_RETRY_INITIAL_SECONDS="${RECEIPT_RETRY_INITIAL_SECONDS:-4}"
pids=()

if [[ ! "$RECEIPT_RETRY_INITIAL_SECONDS" =~ ^[1-9][0-9]{0,3}$ ]] ||
   (( RECEIPT_RETRY_INITIAL_SECONDS > 1800 )); then
  echo '[ERROR] RECEIPT_RETRY_INITIAL_SECONDS must be between 1 and 1800' >&2
  exit 78
fi

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

receipt_worker() {
  local delay="$RECEIPT_RETRY_INITIAL_SECONDS" status
  while true; do
    if "$SCRIPT_DIR/bin/process-receipts.sh"; then
      delay="$RECEIPT_RETRY_INITIAL_SECONDS"
    else
      status=$?
      case "$status" in
        10) sleep 1 ;;
        11) : ;;
        *)
          if (( status != 75 )); then
            log "[ERROR] Receipt worker failed (exit $status)"
          fi
          sleep "$delay"
          delay=$((delay * 2))
          if (( delay > 1800 )); then delay=1800; fi
          ;;
      esac
    fi
  done
}

worker "$SCRIPT_DIR/bin/process-orders.sh" 1 &
pids+=("$!")
worker "$SCRIPT_DIR/bin/poll-payments.sh" 10 &
pids+=("$!")
receipt_worker &
pids+=("$!")
log "Started VERSION=$VERSION"
wait -n "${pids[@]}" || :
exit 1
