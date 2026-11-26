#!/usr/bin/env bash
# brick-basic.sh
# Short Bash brick template with configuration, validation and logging.
set -euo pipefail

SCRIPT_NAME="$(basename "$0")"
SLEEP_SECONDS="${SLEEP_SECONDS:-1}"

main() {
  if [[ "${1:-}" == --help || "${1:-}" == -h ]]; then
    echo "Usage: $SCRIPT_NAME <message>"
    echo "Requires \$HOME"
    return 0
  fi

  [[ $# -eq 1 ]] || error 2 "Expected argument"
  : "${HOME:?}"

  warn "Sleeping for $SLEEP_SECONDS seconds"
  sleep "$SLEEP_SECONDS"

  echo "\$HOME=$HOME, \$1=$1"
}

# region functions

log()   { printf '[%s] [%s] %s\n' "$(date -u +%FT%TZ)" "$SCRIPT_NAME" "$*" >&2; }
warn()  { log "[WARN] $*"; }
error() { local code="$1"; shift; log "[ERROR] $*"; exit "$code"; }

# endregion

main "$@"
