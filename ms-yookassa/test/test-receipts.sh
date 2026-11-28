#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export DB_DIR="$tmp/db" NPD_INN=000000000000 NPD_PASSWORD=fake NPD_DEVICE_ID=test NPD_PAYMENT_TYPE=ACCOUNT
export CALLS="$tmp/calls"
export PATH="$tmp/bin:$PATH"

payments="$DB_DIR/max/users/42/payments"
mkdir -p "$tmp/bin" "$payments/paid" "$payments/paid-test"
cat >"$tmp/bin/curl" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${*: -1}" == */auth/lkfl ]]; then
  jq -e '.password == "fake"' >/dev/null
  echo '{"token":"mock.token"}'
  exit
fi
[[ "${*: -1}" == */income ]]
[[ $(cat) == 'Authorization: Bearer mock.token' ]]
while [[ $# -gt 0 ]]; do
  case "$1" in
    --json) jq -e '.totalAmount == "19.00" and .paymentType == "ACCOUNT" and .services[0].name == "Credits"' <<<"$2" >/dev/null ;;
    --output) output="$2" ;;
  esac
  shift
done
echo called >>"$CALLS"
echo '{"approvedReceiptUuid":"receipt123"}' >"$output"
printf '%s' "${NPD_HTTP:-200}"
MOCK
chmod +x "$tmp/bin/curl"

file="$payments/paid/payment.json"
cat >"$file" <<'PAYMENT'
{"credits":1000,"yookassa":{"status":"succeeded","paid":true,"test":false,"amount":{"currency":"RUB","value":"19.00"},"captured_at":"2026-11-24T20:45:49.216Z","description":"Credits"}}
PAYMENT
jq '.yookassa.test = true' "$file" >"$payments/paid-test/payment.json"
worker="$root/src/bin/process-receipts.sh"

status=0
NPD_HTTP=500 "$worker" 2>"$tmp/errors" || status=$?
[[ $status == 75 && -f "$file" && ! -e "$payments/receipted/payment.json" ]]
grep -q '\[ERROR\]' "$tmp/errors"

cp "$file" "$tmp/original"
"$worker"
[[ ! -e "$file" ]]
jq -e '.credits == 1000 and .receipt.uuid == "receipt123"' "$payments/receipted/payment.json" >/dev/null
grep -q /receipt123/print "$DB_DIR/max/users/42/outbox/receipt_payment.txt"

cp "$tmp/original" "$file"
"$worker"
[[ ! -e "$file" && $(wc -l <"$CALLS") -eq 2 ]]
status=0
"$worker" || status=$?
[[ $status == 10 ]]

cp "$tmp/original" "$payments/paid/rejected.json"
status=0
NPD_HTTP=422 "$worker" || status=$?
[[ $status == 11 && -f "$payments/receipt-failed/rejected.json" ]]
echo 'ok - NPD retry, successful receipt, crash recovery, test exclusion and rejection'
