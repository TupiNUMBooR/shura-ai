#!/usr/bin/env bash
# server-down.sh
set -euo pipefail

SCRIPT_NAME="$(basename "$0")"

main() {
  if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    printf 'Usage: %s\nRequires SSH_ADDRESS and REMOTE_DIR in .env.\n' "$SCRIPT_NAME"
    return 0
  fi
  [[ $# -eq 0 ]] || error 2 "Unexpected arguments"

  [[ -f .env ]] || error 66 "Missing file: .env"
  source ./.env
  [[ -n "${SSH_ADDRESS:-}" ]] || error 66 "SSH_ADDRESS is required"
  [[ -n "${REMOTE_DIR:-}" ]] || error 66 "REMOTE_DIR is required"
  [[ "$REMOTE_DIR" = /* ]] || error 78 "REMOTE_DIR must be an absolute path"
  [[ "$REMOTE_DIR" != *"'"* ]] || error 78 "REMOTE_DIR must not contain a single quote"

  exec ssh -- "$SSH_ADDRESS" "cd '$REMOTE_DIR' && docker compose -f compose.yml down"
}

# region functions

log() { printf '[%s] [%s] %s\n' "$(date -u +%FT%TZ)" "$SCRIPT_NAME" "$*" >&2; }
error() { local code="$1"; shift; log "[ERROR] $*"; exit "$code"; }

# endregion

main "$@"
