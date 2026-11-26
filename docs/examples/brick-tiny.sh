#!/usr/bin/env bash
# brick-tiny.sh
# Tiny Bash brick template with self-printing help and inline checks.
set -euo pipefail

if [[ "${1:-}" == --help || "${1:-}" == -h ]]; then
  cat -- "${BASH_SOURCE[0]}"
  exit
fi

source ./.env

[[ $# -eq 0 ]] || { echo "Unexpected arguments" >&2; exit 2; }
: "${HOME:?}"

echo "HOME=$HOME"
