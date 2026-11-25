#!/usr/bin/env bash
# server-download-shura.sh
set -euo pipefail

SCRIPT_NAME="$(basename "$0")"
tmp_file=""

main() {
  if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    printf 'Usage: %s\nRun from the project root with SSH_ADDRESS and REMOTE_DIR in .env.\nDownloads the entire remote directory as a ZIP in the current directory.\n' "$SCRIPT_NAME"
    return 0
  fi
  [[ $# -eq 0 ]] || error 2 "Unexpected arguments"

  [[ -f .env ]] || error 66 "Missing file: .env"
  source ./.env
  [[ -n "${SSH_ADDRESS:-}" ]] || error 66 "SSH_ADDRESS is required"
  [[ "${REMOTE_DIR:-}" == /* ]] || error 78 "REMOTE_DIR must be an absolute path"
  command -v unzip >/dev/null || error 69 "unzip is required"

  local name parent output remote_command
  name=$(basename -- "$REMOTE_DIR")
  [[ "$name" != / && "$name" != . && "$name" != .. ]] || error 78 "REMOTE_DIR must name a directory"
  parent=$(dirname -- "$REMOTE_DIR")
  output="$name-$(date -u +%Y%m%d-%H%M%SZ).zip"
  remote_command="cd $(shell_quote "$parent") && zip -q -r -y -MM - $(shell_quote "./$name")"

  tmp_file=$(mktemp "./.$output.XXXXXXXX")
  trap 'rm -f -- "$tmp_file"' EXIT

  log "Download $REMOTE_DIR from $SSH_ADDRESS"
  ssh -T -- "$SSH_ADDRESS" "$remote_command" > "$tmp_file"

  unzip -tq "$tmp_file" >/dev/null || error 65 "Downloaded ZIP failed validation"
  ln -- "$tmp_file" "./$output"
  printf '%s\n' "$output"
}

# region functions

shell_quote() { printf "'%s'" "${1//\'/\'\\\'\'}"; }
log() { printf '[%s] [%s] %s\n' "$(date -u +%FT%TZ)" "$SCRIPT_NAME" "$*" >&2; }
error() { local code="$1"; shift; log "[ERROR] $*"; exit "$code"; }

# endregion

main "$@"
