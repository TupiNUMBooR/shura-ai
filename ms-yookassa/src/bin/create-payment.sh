#!/usr/bin/env bash
# create-payment.sh: create a redirect payment, print the original YooKassa JSON.
set -euo pipefail

: "${YOOKASSA_SHOP_ID:?YOOKASSA_SHOP_ID is required}"
: "${YOOKASSA_SECRET_KEY:?YOOKASSA_SECRET_KEY is required}"
YOOKASSA_API_URL="${YOOKASSA_API_URL:-https://api.yookassa.ru/v3}"

main() (
  [[ $# -eq 4 ]] || { echo 'Usage: create-payment.sh RUB IDEMPOTENCE_KEY CREDITS RETURN_URL' >&2; return 2; }
  local rub="$1" key="$2" credits="$3" return_url="$4" response code
  [[ "$rub" =~ ^[1-9][0-9]*$ && -n "$key" && "$credits" =~ ^[1-9][0-9]*$ ]] || return 2
  if [[ ! "$return_url" =~ ^https://[^/?#[:space:]@]+([/?#][^[:space:]]*)?$ ]]; then
    echo 'Invalid return_url: expected an HTTPS URL' >&2
    return 65
  fi
  response=$(mktemp)
  trap 'rm -f "$response"' EXIT
  code=$(jq -nc --arg value "$rub" --arg credits "$credits" --arg return_url "$return_url" '
    {
      amount: {value: ($value + ".00"), currency: "RUB"},
      capture: true,
      confirmation: {type: "redirect", return_url: $return_url},
      description: ($credits + " кредитов для Шуры")
    }
  ' |
    curl --silent --show-error --connect-timeout 10 --max-time 45 \
      --user "$YOOKASSA_SHOP_ID:$YOOKASSA_SECRET_KEY" \
      --header 'Content-Type: application/json' --header "Idempotence-Key: $key" \
      --output "$response" --write-out '%{http_code}' --data-binary @- \
      "${YOOKASSA_API_URL%/}/payments") || return 69
  if [[ "$code" != 200 ]]; then
    echo "YooKassa create HTTP $code: $(cat "$response")" >&2
    case "$code" in 400|401|403|404|422) return 65;; *) return 75;; esac
  fi
  jq -e '(.id | type=="string" and length>0) and (.status=="pending" or .status=="succeeded") and (.confirmation.confirmation_url | type=="string" and length>0)' "$response" >/dev/null || return 65
  cat "$response"
)
main "$@"
