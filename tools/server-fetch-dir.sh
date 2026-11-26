#!/usr/bin/env bash
# server-fetch-dir.sh
set -euo pipefail

if [[ "${1:-}" == --help || "${1:-}" == -h ]]; then
  cat -- "${BASH_SOURCE[0]}"
  exit
fi

source ./.env

[[ $# -eq 0 ]] || { echo "Unexpected arguments" >&2; exit 2; }
: "${SSH_ADDRESS:?}"
: "${REMOTE_DIR:?}"
[[ "$REMOTE_DIR" = /* ]] || { echo "REMOTE_DIR must be an absolute path" >&2; exit 78; }
[[ "$REMOTE_DIR" != *"'"* ]] || { echo "REMOTE_DIR must not contain a single quote" >&2; exit 78; }
command -v unzip >/dev/null || { echo "unzip is required" >&2; exit 69; }

remote_dir=${REMOTE_DIR%"${REMOTE_DIR##*[!/]}"}
name=${remote_dir##*/}
[[ -n "$name" && "$name" != . && "$name" != .. ]] || { echo "REMOTE_DIR must name a directory" >&2; exit 78; }
parent=${remote_dir%/*}
parent=${parent:-/}

output="$name-$(date -u +%Y%m%d-%H%M%SZ).zip"
tmp_file=$(mktemp ./.download-server-directory.XXXXXXXX)
trap 'rm -f -- "$tmp_file"' EXIT

ssh -T -- "$SSH_ADDRESS" "
  cd '${parent//\'/\'\\\'\'}' || exit
  dir='./${name//\'/\'\\\'\'}'
  test -d \"\$dir\" || { echo 'REMOTE_DIR is not a directory' >&2; exit 78; }
  printf '%s' 'Source size: ' >&2
  du -sh --apparent-size -- \"\$dir\" >&2 || exit
  zip -q -r -y -MM - \"\$dir\"
" | dd bs=1M status=progress > "$tmp_file"

unzip -tq "$tmp_file" >/dev/null || { echo "Downloaded ZIP failed validation" >&2; exit 65; }
ln -T -- "$tmp_file" "$output"
printf '%s\n' "$output"
