#!/usr/bin/env bash
# process-orders.sh: one pass over all messenger orders.
set -euo pipefail
SCRIPT_NAME="${0##*/}"
DB_DIR="${DB_DIR:-/db}"
PRICES_FILE="${PRICES_FILE:-$(dirname "$0")/../config/credit-packages.json}"
CREATE_PAYMENT="${CREATE_PAYMENT:-$(dirname "$0")/create-payment.sh}"

log() { printf '[%s] [%s] %s\n' "$(date -u +%FT%TZ)" "$SCRIPT_NAME" "$*" >&2; }

main() {
  [[ $# -eq 0 ]] || return 2
  [[ -f "$PRICES_FILE" ]] || { log '[ERROR] Missing prices.json'; return 66; }
  [[ -d "$DB_DIR" ]] || return 0
  local order credits rub parent uid_dir tmp response id path out key status
  while IFS= read -r -d '' order; do
    parent="${order%/orders/*}"
    uid_dir="${parent%/payments}"
    credits="${order##*/}"; credits="${credits%.json}"
    if [[ ! "$credits" =~ ^[1-9][0-9]*$ ]]; then rm -f -- "$order"; continue; fi
    rub=$(jq -er --argjson credits "$credits" '.packages[] | select(.credits==$credits) | .rub | select(type=="number" and .>0)' "$PRICES_FILE") || { log "[WARN] Invalid package: $order"; rm -f -- "$order"; continue; }
    # Keep the key stable across retries, even if the remote request timed out.
    key=$(jq -r '.idempotence_key // empty' "$order" 2>/dev/null) || key=""
    if [[ -z "$key" ]]; then
      key=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || printf '%s-%s-%s' "$(date +%s%N)" "$credits" "$RANDOM")
      tmp=$(mktemp "$parent/orders/.order.XXXXXX")
      if jq -c --arg key "$key" --argjson credits "$credits" '. + {credits:$credits,idempotence_key:$key}' "$order" >"$tmp"; then mv -f "$tmp" "$order"; else rm -f "$tmp"; rm -f "$order"; continue; fi
    fi
    if response=$("$CREATE_PAYMENT" "$rub" "$key"); then
      :
    else
      status=$?
      if (( status == 65 )); then
        log "[WARN] Invalid order, deleted: $order"
        rm -f -- "$order"
      else
        log "[WARN] Create failed; retrying later: $order"
      fi
      continue
    fi
    id=$(jq -r '.id' <<<"$response")
    [[ "$id" =~ ^[a-zA-Z0-9-]+$ ]] || { log '[WARN] Invalid payment ID'; continue; }
    mkdir -p "$parent/processing" "$uid_dir/outbox"
    path="$parent/processing/$id.json"
    out="$uid_dir/outbox/payment_$id.json"
    tmp=$(mktemp "$parent/orders/.payment.XXXXXX")
    if ! jq -nc --argjson payment "$response" --argjson credits "$credits" --argjson rub "$rub" --arg key "$key" \
      '{credits:$credits,rub:$rub,idempotence_key:$key,yookassa:$payment}' >"$tmp"; then rm -f "$tmp"; continue; fi
    # Rename order to payment ID; outbox contains an independent copy.
    mv -f -- "$tmp" "$order" || return 73
    tmp=$(mktemp "$uid_dir/outbox/.payment.XXXXXX")
    cp -- "$order" "$tmp" || { rm -f "$tmp"; return 73; }
    mv -f -- "$tmp" "$out" || return 73
    mv -f -- "$order" "$path" || return 73
    log "Created payment $id: $credits credits, $rub RUB"
  done < <(find "$DB_DIR" -type f -path '*/users/*/payments/orders/*.json' -print0 | sort -z)
}
main "$@"
