#!/usr/bin/env bash
# get-payment.sh: fetch full YooKassa payment object.
set -euo pipefail
: "${YOOKASSA_SHOP_ID:?YOOKASSA_SHOP_ID is required}"
: "${YOOKASSA_SECRET_KEY:?YOOKASSA_SECRET_KEY is required}"
YOOKASSA_API_URL="${YOOKASSA_API_URL:-https://api.yookassa.ru/v3}"
main() (
  [[ $# -eq 1 && "$1" =~ ^[a-zA-Z0-9-]+$ ]] || return 2
  local response code
  response=$(mktemp)
  trap 'rm -f "$response"' EXIT
  code=$(curl --silent --show-error --connect-timeout 10 --max-time 45 \
      --user "$YOOKASSA_SHOP_ID:$YOOKASSA_SECRET_KEY" \
      --output "$response" --write-out '%{http_code}' \
      "${YOOKASSA_API_URL%/}/payments/$1") || return 69
  if [[ "$code" != 200 ]]; then echo "YooKassa get HTTP $code: $(cat "$response")" >&2; return 75; fi
  jq -e --arg id "$1" '.id == $id and (.status | type == "string")' "$response" >/dev/null || return 65
  cat "$response"
)
main "$@"
