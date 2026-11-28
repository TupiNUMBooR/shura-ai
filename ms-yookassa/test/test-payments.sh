#!/usr/bin/env bash
# test-payments.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/db/max/users/42/payments/orders" "$TMP/db/telegram/users/7/payments/orders"

cat >"$TMP/bin/create-payment" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
[[ "${CREATE_FAIL:-0}" == 0 ]] || exit "${CREATE_FAIL}"
[[ "$1" == 79 || "$1" == 19 ]] || exit 2
case "$3:$4" in
  '5000:https://web.max.ru/829005994'|'1000:https://t.me/example_bot') ;;
  *) exit 2 ;;
esac
id="test-$(printf '%s' "$2" | tr -cd 'a-zA-Z0-9-' | cut -c1-30)"
jq -nc --arg id "$id" --arg value "$1.00" '{id:$id,status:"pending",amount:{value:$value,currency:"RUB"},confirmation:{type:"redirect",confirmation_url:("https://pay.example/"+$id)},merchant_metadata:{keep:"all fields"}}'
MOCK
cat >"$TMP/bin/get-payment" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
[[ "${GET_FAIL:-0}" == 0 ]] || exit 69
jq -nc --arg id "$1" --arg status "${PAYMENT_STATUS:-pending}" '{id:$id,status:$status,amount:{value:"79.00",currency:"RUB"},test:(env.PAYMENT_TEST == "1"),metadata:{polled:true}}'
MOCK
chmod +x "$TMP/bin/"*
export DB_DIR="$TMP/db" CREATE_PAYMENT="$TMP/bin/create-payment" GET_PAYMENT="$TMP/bin/get-payment"
orders="$ROOT/src/bin/process-orders.sh"
poll="$ROOT/src/bin/poll-payments.sh"

assert() { "$@" || { echo "FAIL: $*" >&2; exit 1; }; }

echo '{"credits":5000,"return_url":"https://web.max.ru/829005994"}' >"$DB_DIR/max/users/42/payments/orders/5000.json"
echo '{"credits":1000,"return_url":"https://t.me/example_bot"}' >"$DB_DIR/telegram/users/7/payments/orders/1000.json"
echo '{"credits":1000}' >"$DB_DIR/max/users/42/payments/orders/1000.json"
SHOP_ENABLED=0 bash "$orders" >/dev/null 2>&1
assert jq -e 'has("idempotence_key") | not' "$DB_DIR/max/users/42/payments/orders/5000.json" >/dev/null
assert test ! -e "$DB_DIR/max/users/42/payments/processing"
CREATE_FAIL=69 bash "$orders" >/dev/null 2>&1
assert test -f "$DB_DIR/max/users/42/payments/orders/5000.json"
assert test ! -e "$DB_DIR/max/users/42/payments/orders/1000.json"
key=$(jq -r .idempotence_key "$DB_DIR/max/users/42/payments/orders/5000.json")
[[ -n "$key" ]] || exit 1
bash "$orders" >/dev/null
assert test ! -e "$DB_DIR/max/users/42/payments/orders/5000.json"
assert test ! -e "$DB_DIR/telegram/users/7/payments/orders/1000.json"
file=$(find "$DB_DIR/max/users/42/payments/processing" -name '*.json' | head -1)
assert test -f "$file"
assert jq -e --arg url "https://pay.example/$(basename "${file%.json}")" '
  . == {
    text: "Оплата 5000 кредитов за 79 ₽",
    buttons: [[{type: "link", text: "Оплатить", url: $url}]]
  }
' "$DB_DIR/max/users/42/outbox/message_payment_$(basename "$file")" >/dev/null
assert jq -e --arg key "$key" '
  .idempotence_key == $key and .credits == 5000 and .rub == 79
  and .return_url == "https://web.max.ru/829005994"
  and .yookassa.merchant_metadata.keep == "all fields"
' "$file" >/dev/null
PAYMENT_STATUS=pending bash "$poll"
assert test -f "$file"
GET_FAIL=69 bash "$poll" >/dev/null 2>&1
assert test -f "$file"
SHOP_ENABLED=0 PAYMENT_TEST=1 PAYMENT_STATUS=succeeded bash "$poll" >/dev/null 2>"$TMP/success.log"
assert grep -Fq "[SUCCESS] Payment $(basename "${file%.json}") completed: +5000 credits, 79 RUB, user=42" "$TMP/success.log"
assert test ! -e "$file"
assert test -f "$DB_DIR/max/users/42/payments/paid-test/$(basename "$file")"
assert test -f "$DB_DIR/max/users/42/outbox/$(basename "${file%.json}").txt"
assert test "$(cat "$DB_DIR/max/users/42/credits_received.txt")" = 5000
assert grep -q "Твой баланс: 5000 кредитов" "$DB_DIR/max/users/42/outbox/$(basename "${file%.json}").txt"
assert test "$(cat "$DB_DIR/telegram/users/7/credits_received.txt")" = 1000
bash "$poll" >/dev/null
assert test "$(cat "$DB_DIR/max/users/42/credits_received.txt")" = 5000

# Canceled payment remains in failed and never credits the user.
echo '{"credits":5000,"return_url":"https://web.max.ru/829005994"}' >"$DB_DIR/max/users/42/payments/orders/5000.json"
bash "$orders" >/dev/null
PAYMENT_STATUS=canceled bash "$poll" >/dev/null
assert test "$(cat "$DB_DIR/max/users/42/credits_received.txt")" = 5000
[[ $(find "$DB_DIR/max/users/42/payments/failed" -name '*.json' | wc -l) -eq 1 ]] || exit 1

echo 'ok - orders, temporary failures, complete scan, successful/canceled payments and credits'
