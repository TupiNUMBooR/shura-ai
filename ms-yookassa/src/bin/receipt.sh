#!/usr/bin/env bash
# Read a confirmed YooKassa payment from stdin and append its NPD receipt.
set +x
set -euo pipefail

main() (
  [[ $# -eq 0 ]] || return 2
  local api=https://lknpd.nalog.ru/api/v1
  local payment body token response code uuid
  local -a http=(curl -q --silent --show-error --connect-timeout 10 --max-time 30)

  payment=$(jq -ces 'select(length == 1) | .[0] | objects' ) || return 65
  body=$(jq -ce --arg now "$(date -u +%FT%TZ)" --arg type "${NPD_PAYMENT_TYPE:-}" '
    .yookassa
    | if .status == "succeeded" and .paid == true and .test == false
         and .amount.currency == "RUB"
         and (.amount.value | strings | (test("^[0-9]+[.][0-9]{2}$") and (tonumber > 0)))
         and (.captured_at | strings | length > 0)
         and (.description | strings | length > 0)
      then {
        requestTime: $now, operationTime: .captured_at, paymentType: $type,
        ignoreMaxTotalIncomeRestriction: false,
        client: {incomeType: "FROM_INDIVIDUAL"},
        services: [{name: .description, amount: .amount.value, quantity: 1}],
        totalAmount: .amount.value
      }
      else error("Invalid YooKassa payment for NPD") end
  ' <<<"$payment") || return 65

  if [[ ! "${NPD_INN:-}" =~ ^[0-9]{12}$ || -z "${NPD_DEVICE_ID:-}" || -z "${NPD_PASSWORD:-}" ]]; then
    echo 'NPD_INN, NPD_DEVICE_ID and NPD_PASSWORD are required' >&2
    return 78
  fi
  if [[ ! "${NPD_PAYMENT_TYPE:-}" =~ ^(CASH|ACCOUNT)$ ]]; then
    echo 'Set NPD_PAYMENT_TYPE to the value verified for online payments (CASH or ACCOUNT)' >&2
    return 78
  fi
  token=$(printf '%s' "$NPD_PASSWORD" |
    jq -Rs --arg inn "$NPD_INN" --arg device "$NPD_DEVICE_ID" '
      {username: $inn, password: .,
       deviceInfo: {sourceDeviceId: $device, sourceType: "WEB",
                    appVersion: "1.0.0", metaDetails: {}}}
    ' |
    "${http[@]}" --fail --json @- "$api/auth/lkfl" |
    jq -er '.token | strings | select(test("^[A-Za-z0-9._~+/=-]+$"))') || {
      echo 'NPD authentication failed' >&2
      return 75
    }

  response=$(mktemp) || return 73
  trap 'rm -f -- "$response"' EXIT
  code=$(printf 'Authorization: Bearer %s\n' "$token" |
    "${http[@]}" -H @- --json "$body" --output "$response" --write-out '%{http_code}' "$api/income") ||
    return 75
  case "$code" in
    2??) ;;
    400|422)
      echo "NPD income rejected: HTTP $code" >&2
      return 65 ;;
    *)
      echo "NPD income failed: HTTP $code" >&2
      return 75 ;;
  esac

  uuid=$(jq -er '.approvedReceiptUuid | strings | select(test("^[a-zA-Z0-9-]+$"))' "$response") || {
    echo 'NPD income response lacks a valid receipt ID' >&2
    return 75
  }
  jq -c --arg uuid "$uuid" --arg url "$api/receipt/$NPD_INN/$uuid/print" \
    '.receipt = {uuid: $uuid, url: $url}' <<<"$payment"
)

main "$@"
