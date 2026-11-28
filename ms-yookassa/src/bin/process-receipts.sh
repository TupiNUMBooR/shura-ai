#!/usr/bin/env bash
# Process one randomly selected paid order. Exit 10 when the queue is empty.
set -euo pipefail

SCRIPT_DIR="$(dirname -- "${BASH_SOURCE[0]}")"
DB_DIR="${DB_DIR:-/db}"

log() { printf '[%s] [process-receipts.sh] %s\n' "$(date -u +%FT%TZ)" "$*" >&2; }

main() (
  [[ $# -eq 0 ]] || return 2
  [[ -d "$DB_DIR" ]] || return 10
  local file name payments user archive destination tmp= status url
  trap '[[ -z "$tmp" ]] || rm -f -- "$tmp"' EXIT

  file=$(find "$DB_DIR" -type f -path '*/users/*/payments/paid/*.json' -print0 |
    shuf -z -n 1 | { IFS= read -r -d '' selected && printf '%s' "$selected" || :; }) || return 73
  [[ -n "$file" ]] || return 10

  name="${file##*/}"
  payments="${file%/paid/*}"
  user="${payments%/payments}"
  archive="$payments/receipted/$name"

  if [[ ! -f "$archive" ]]; then
    mkdir -p "$payments/receipted" || return 73
    tmp=$(mktemp "$payments/receipted/.receipt.XXXXXX") || return 73
    if "$SCRIPT_DIR/receipt.sh" <"$file" >"$tmp"; then
      mv -f -- "$tmp" "$archive" || return 73
      tmp=
    else
      status=$?
      if (( status == 65 )); then
        log "[ERROR] Receipt rejected: $name"
        mkdir -p "$payments/receipt-failed" || return 73
        mv -f -- "$file" "$payments/receipt-failed/$name" || return 73
        return 11
      fi
      log "[ERROR] Receipt attempt failed: $name (exit $status)"
      return 75
    fi
  fi

  url=$(jq -er '.receipt.url | strings | select(length > 0)' "$archive") || return 73
  mkdir -p "$user/outbox" || return 73
  destination="$user/outbox/receipt_${name%.json}.txt"
  if [[ ! -f "$destination" ]]; then
    tmp=$(mktemp "$user/outbox/.receipt.XXXXXX") || return 73
    printf 'Чек об оплате: %s\n' "$url" >"$tmp" || return 73
    mv -f -- "$tmp" "$destination" || return 73
    tmp=
  fi
  rm -- "$file" || return 73
  log "[SUCCESS] Receipt saved: $name"
)

main "$@"
