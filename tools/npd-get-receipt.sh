#!/usr/bin/env bash
# Usage: bash tools/npd-get-receipt.sh [RECEIPT_ID]
set +x
set -euo pipefail

if [[ "${1:-}" == --help || "${1:-}" == -h ]]; then
  printf 'Usage: %s [RECEIPT_ID]\n' "${0##*/}"
  exit 0
fi

if [[ $# -gt 1 || ( $# -eq 1 && ! "${1:-}" =~ ^[a-zA-Z0-9-]+$ ) ]]; then
  printf 'Usage: %s [RECEIPT_ID]\n' "${0##*/}" >&2
  exit 2
fi

source ./.env
: "${NPD_INN:?NPD_INN is required}"
: "${NPD_DEVICE_ID:?NPD_DEVICE_ID is required}"
: "${NPD_PASSWORD:?NPD_PASSWORD is required}"

api=https://lknpd.nalog.ru/api/v1

request() {
  local method=$1 path=$2
  shift 2
  local response status

  if ! response=$(curl -q -sS --connect-timeout 10 --max-time 30 \
    --request "$method" --write-out $'\n%{http_code}' \
    "$@" "$api$path"); then
    printf 'ERROR %s %s — curl failed\n' "$method" "$path" >&2
    return 75
  fi

  status=${response##*$'\n'}
  response=${response%$'\n'*}

  if [[ "$status" != 2[0-9][0-9] ]]; then
    printf 'ERROR %s %s — HTTP %s\n%s\n' \
      "$method" "$path" "$status" "$response" >&2
    return 22
  fi

  printf '%s\n' "$response"
}

auth_response=$(printf '%s' "$NPD_PASSWORD" |
  jq -Rs --arg inn "$NPD_INN" --arg device "$NPD_DEVICE_ID" '
    {username: $inn, password: .,
     deviceInfo: {sourceDeviceId: $device, sourceType: "WEB",
                  appVersion: "1.0.0", metaDetails: {}}}
  ' |
  request POST /auth/lkfl --json @-)

if ! token=$(jq -er '.token | strings | select(length > 0)' <<<"$auth_response"); then
  printf 'ERROR POST /auth/lkfl — response has no token\n' >&2
  exit 65
fi

if [[ $# -eq 1 ]]; then
  path="/receipt/$NPD_INN/$1/json"
else
  path='/incomes?limit=10&offset=0&sortBy=operation_time:desc'
fi

printf 'Authorization: Bearer %s\n' "$token" |
  request GET "$path" -H @- |
  jq -e .
