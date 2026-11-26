#!/usr/bin/env bash
# server-ssh.sh
set -euo pipefail

if [[ "${1:-}" == --help || "${1:-}" == -h ]]; then
  cat -- "${BASH_SOURCE[0]}"
  exit
fi

source ./.env

: "${SSH_ADDRESS:?}"

exec ssh -- "$SSH_ADDRESS" "$@"
