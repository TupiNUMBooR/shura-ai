#!/usr/bin/env bash
# brick2.sh - Minimal Bash brick template with configuration, validation and logging.
set -euo pipefail

SCRIPT_NAME="$(basename "$0")"

# required environment
: "${API_KEY:?}"

# optional environment
SLEEP_SECONDS="${SLEEP_SECONDS:-1}"

main() {
  [[ $# -eq 1 ]] || error 2 "Expected argument"

  log "Sleeping for $SLEEP_SECONDS seconds"
  sleep "$SLEEP_SECONDS"
}

# region functions

log()   { printf '[%s] [%s] %s\n' "$(date -u +%FT%TZ)" "$SCRIPT_NAME" "$*" >&2; }
warn()  { log "[WARN] $*"; }
error() { local code="$1"; shift; log "[ERROR] $*"; exit "$code"; }

# endregion

main "$@"
