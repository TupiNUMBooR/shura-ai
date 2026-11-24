#!/usr/bin/env bash
# server-ssh.sh
set -euo pipefail

SCRIPT_NAME="$(basename "$0")"

main() {
  if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    printf 'Usage: %s [COMMAND [ARG...]]\nRequires SSH_ADDRESS in .env.\n' "$SCRIPT_NAME"
    return 0
  fi

  [[ -f .env ]] || error 66 "Missing file: .env"
  source ./.env
  [[ -n "${SSH_ADDRESS:-}" ]] || error 66 "SSH_ADDRESS is required"

  exec ssh -- "$SSH_ADDRESS" "$@"
}

# region functions

log() { printf '[%s] [%s] %s\n' "$(date -u +%FT%TZ)" "$SCRIPT_NAME" "$*" >&2; }
error() { local code="$1"; shift; log "[ERROR] $*"; exit "$code"; }

# endregion

main "$@"
