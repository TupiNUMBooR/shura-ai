#!/usr/bin/env bash
# poll-payments.sh: check ALL processing payments in one pass.
set -euo pipefail
SCRIPT_NAME="${0##*/}"
DB_DIR="${DB_DIR:-/db}"
GET_PAYMENT="${GET_PAYMENT:-$(dirname "$0")/get-payment.sh}"
log() { printf '[%s] [%s] %s\n' "$(date -u +%FT%TZ)" "$SCRIPT_NAME" "$*" >&2; }

main() {
  [[ $# -eq 0 ]] || return 2
  [[ -d "$DB_DIR" ]] || return 0
  local file parent uid_dir id result status credits rub previous spent balance tmp message paid_dir
  while IFS= read -r -d '' file; do
    parent="${file%/processing/*}"
    uid_dir="${parent%/payments}"
    id="${file##*/}"; id="${id%.json}"
    if ! result=$("$GET_PAYMENT" "$id"); then log "[WARN] Status unavailable: $id"; continue; fi
    status=$(jq -r '.status' <<<"$result")
    case "$status" in
      pending|waiting_for_capture) continue ;;
      succeeded|canceled) ;;
      *) log "[WARN] Unknown payment status: $id $status"; continue ;;
    esac
    tmp=$(mktemp "$parent/processing/.payment.XXXXXX")
    if jq -c --argjson payment "$result" '.yookassa = $payment' "$file" >"$tmp"; then mv -f "$tmp" "$file"; else rm -f "$tmp"; continue; fi
    if [[ "$status" == succeeded ]]; then
      credits=$(jq -er '.credits | select(type=="number" and .>0)' "$file") || continue
      rub=$(jq -r '.rub // .yookassa.amount.value // "unknown"' "$file")
      previous=0
      [[ ! -f "$uid_dir/credits_received.txt" ]] || previous=$(<"$uid_dir/credits_received.txt")
      [[ "$previous" =~ ^[0-9]+$ ]] || { log "[WARN] Invalid credits: $uid_dir"; continue; }
      tmp=$(mktemp "$uid_dir/.received.XXXXXX")
      printf '%s\n' "$((previous + credits))" >"$tmp"
      mv -f "$tmp" "$uid_dir/credits_received.txt" || return 73
      paid_dir=paid
      if [[ $(jq -r '.yookassa.test' "$file") == true ]]; then
        paid_dir=paid-test
      fi
      mkdir -p "$parent/$paid_dir" "$uid_dir/outbox"
      mv -f -- "$file" "$parent/$paid_dir/$id.json"
      spent=0
      [[ ! -f "$uid_dir/credits_spent.txt" ]] || spent=$(<"$uid_dir/credits_spent.txt")
      balance=$(jq -nr --arg received "$((previous + credits))" --arg spent "$spent" '($received | tonumber) - ($spent | tonumber)')
      tmp=$(mktemp "$uid_dir/outbox/.payment.XXXXXX")
      printf 'Платёж успешно завершён! 💜\n\nНачислено: %s кредитов\nТвой баланс: %s кредитов\n' "$credits" "$balance" >"$tmp"
      mv -f "$tmp" "$uid_dir/outbox/$id.txt"
      log "[SUCCESS] Payment $id completed: +$credits credits, $rub RUB, user=${uid_dir##*/}"
    else
      mkdir -p "$parent/failed"
      mv -f -- "$file" "$parent/failed/$id.json"
      log "Canceled $id"
    fi
  done < <(find "$DB_DIR" -type f -path '*/users/*/payments/processing/*.json' -print0 | sort -z)
}
main "$@"
