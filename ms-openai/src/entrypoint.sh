#!/usr/bin/env bash
# entrypoint.sh — process pending user messages, one user at a time.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# optional environment
DB_DIR="${DB_DIR:-./db}"
PROCESS_USER="${PROCESS_USER:-$SCRIPT_DIR/bin/process-user.sh}"
POLL_SECONDS="${POLL_SECONDS:-1}"

pid=''

cleanup() {
  trap - TERM INT EXIT
  if [[ -n "$pid" ]]; then
    kill "$pid" 2>/dev/null || :
    wait "$pid" 2>/dev/null || :
  fi
}

trap cleanup EXIT
trap 'exit 0' TERM INT

needs_processing() {
  local dir="$1" latest

  # A new inbox message triggers processing; delayed messages alone do not.
  compgen -G "$dir/inbox/*.txt" >/dev/null && return 0

  # A generated user history entry without a matching assistant entry.
  [[ -d "$dir/ai" ]] || return 1
  latest="$(find "$dir/ai" -maxdepth 1 -type f -name '*_u.json' -printf '%f\n' | LC_ALL=C sort | tail -n 1)"
  [[ -n "$latest" && ! -f "$dir/ai/${latest%_u.json}_a.json" ]]
}

main() {
  local uid_dir found

  while true; do
    found=0
    for uid_dir in "$DB_DIR"/*/users/*; do
      [[ -d "$uid_dir" ]] || continue
      needs_processing "$uid_dir" || continue
      found=1

      "$PROCESS_USER" "$uid_dir" &
      pid=$!
      if ! wait "$pid"; then
        pid=''
        exit 1  # Docker handles restart/backoff.
      fi
      pid=''
    done
    (( found )) || sleep "$POLL_SECONDS"
  done
}

main "$@"
