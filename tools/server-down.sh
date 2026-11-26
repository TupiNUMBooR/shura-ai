#!/usr/bin/env bash
# server-down.sh
set -euo pipefail

if [[ "${1:-}" == --help || "${1:-}" == -h ]]; then
  cat -- "${BASH_SOURCE[0]}"
  exit
fi

[[ $# -eq 0 ]] || { echo "Unexpected arguments" >&2; exit 2; }

source ./.env

: "${SSH_ADDRESS:?}"
: "${REMOTE_DIR:?}"
[[ "$REMOTE_DIR" = /* ]] || { echo "REMOTE_DIR must be an absolute path" >&2; exit 78; }
[[ "$REMOTE_DIR" != *"'"* ]] || { echo "REMOTE_DIR must not contain a single quote" >&2; exit 78; }

exec ssh -- "$SSH_ADDRESS" "cd '$REMOTE_DIR' && docker compose -f compose.yml down"
