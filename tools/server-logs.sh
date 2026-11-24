#!/usr/bin/env bash
# server-logs.sh
set -euo pipefail

SCRIPT_NAME="$(basename "$0")"

main() {
  if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    printf 'Usage: %s [LINES]\nRequires SSH_ADDRESS and REMOTE_DIR in .env (LINES defaults to 200).\n' "$SCRIPT_NAME"
    return 0
  fi
  [[ $# -le 1 ]] || error 2 "Expected at most one argument"
  local lines="${1-200}"
  [[ "$lines" =~ ^[1-9][0-9]*$ ]] || error 2 "LINES must be a positive integer"

  [[ -f .env ]] || error 66 "Missing file: .env"
  source ./.env
  [[ -n "${SSH_ADDRESS:-}" ]] || error 66 "SSH_ADDRESS is required"
  [[ -n "${REMOTE_DIR:-}" ]] || error 66 "REMOTE_DIR is required"
  [[ "$REMOTE_DIR" = /* ]] || error 78 "REMOTE_DIR must be an absolute path"
  [[ "$REMOTE_DIR" != *"'"* ]] || error 78 "REMOTE_DIR must not contain a single quote"

  exec ssh -t -- "$SSH_ADDRESS" \
    "cd '$REMOTE_DIR' || exit; docker compose -f compose.yml logs -f --tail=$lines; exec \"\${SHELL:-/bin/sh}\" -l"
}

# region functions

log() { printf '[%s] [%s] %s\n' "$(date -u +%FT%TZ)" "$SCRIPT_NAME" "$*" >&2; }
error() { local code="$1"; shift; log "[ERROR] $*"; exit "$code"; }

# endregion

main "$@"
