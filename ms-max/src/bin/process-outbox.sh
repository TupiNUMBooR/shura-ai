#!/usr/bin/env bash
# process-outbox.sh
set -euo pipefail

SCRIPT_NAME="$(basename "$0")"

# optional environment
DB_DIR="${DB_DIR:-./db}"
POST_MESSAGE="${POST_MESSAGE:-$(dirname "${BASH_SOURCE[0]}")/post-message.sh}"

main() {
  [[ $# -eq 0 ]] || error 2 "Unexpected arguments"

  local file uid uid_dir attempt

  [[ -d "$DB_DIR/users" ]] || return 0

  file=$(find "$DB_DIR/users" -path '*/outbox/*.txt' -type f | sort | head -n 1)
  [[ -n "$file" ]] || return 0

  uid_dir="${file%/outbox/*}"
  uid="${uid_dir##*/}"

  if [[ "$uid" =~ ^[0-9]+$ ]]; then
    for attempt in 1 2 3; do
      if "$POST_MESSAGE" "user_id=$uid" < "$file" > /dev/null; then
        rm -- "$file" || error 73 "Cannot remove $file"
        log "Sent to $uid"
        return 0
      fi
      (( attempt < 3 )) && sleep 1
    done
  fi

  mkdir -p "$uid_dir/outbox-failed"
  mv -- "$file" "$uid_dir/outbox-failed/" \
    || error 73 "Cannot move failed message: $file"

  log "[WARN] Failed to send to $uid (moved to outbox-failed)"
}

# region functions

log()   { printf '[%s] [%s] %s\n' "$(date -u +%FT%TZ)" "$SCRIPT_NAME" "$*" >&2; }
error() { local code="$1"; shift; log "[ERROR] $*"; exit "$code"; }

# endregion

main "$@"
