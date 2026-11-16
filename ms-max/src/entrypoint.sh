#!/usr/bin/env bash
# entrypoint.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

pids=()

cleanup() {
  trap - TERM INT EXIT
  kill "${pids[@]}" 2>/dev/null || :
  wait 2>/dev/null || :
}

trap cleanup EXIT
trap 'exit 0' TERM INT

worker() {
  while true; do
    "$1" || exit 1
  done
}

worker "$SCRIPT_DIR/bin/process-inbox.sh" &
pids+=("$!")

# worker "$SCRIPT_DIR/bin/process-outbox.sh" &
# pids+=("$!")

wait -n "${pids[@]}" || :
exit 1
