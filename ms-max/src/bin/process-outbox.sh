#!/usr/bin/env bash
# process-outbox.sh
set -euo pipefail

SCRIPT_NAME="$(basename "$0")"

# optional environment
DB_DIR="${DB_DIR:-/db}"
POST_MESSAGE="${POST_MESSAGE:-$(dirname "${BASH_SOURCE[0]}")/post-message.sh}"

main() {
  [[ $# -eq 0 ]] || error 2 "Unexpected arguments"

  local file uid mid
  file=$(find "$DB_DIR/users" -path '*/outbox/*.txt' -type f | sort | head -n 1)
  [[ -n "$file" ]] || return 0

  uid="${file%/outbox/*}"
  uid="${uid##*/}"

  "$POST_MESSAGE" "user_id=$uid" < "$file" > /dev/null || error 75 "Failed to send to $uid"

  rm -- "$file" || error 73 "Cannot remove $file"
  log "Sent to $uid"
}

# region functions

log()   { printf '[%s] [%s] %s\n' "$(date -u +%FT%TZ)" "$SCRIPT_NAME" "$*" >&2; }
error() { local code="$1"; shift; log "[ERROR] $*"; exit "$code"; }

# endregion

main "$@"
