#!/usr/bin/env bash
# test-api.sh: real API scripts with a fake curl (including EXIT cleanup).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"
cat >"$TMP/bin/curl" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
output=""; url=""; body=0; payload=""
while (($#)); do
  case "$1" in
    --output) output="$2"; shift 2 ;;
    --write-out) shift 2 ;;
    --data-binary) body=1; shift 2 ;;
    *) url="$1"; shift ;;
  esac
done
if (( body )); then payload=$(cat); [[ "$payload" == *'"description":"1000 кредитов для Шуры"'* ]] || exit 17; fi
if [[ "${HTTP_CODE:-200}" != 200 ]]; then
  printf '%s\n' '{"type":"error","description":"test HTTP failure"}' >"$output"
  printf '%s' "$HTTP_CODE"
elif [[ "$url" == */payments ]]; then
  printf '%s\n' '{"id":"pay-123","status":"pending","confirmation":{"confirmation_url":"https://pay.example/test"}}' >"$output"
  printf '200'
else
  printf '%s\n' '{"id":"pay-123","status":"succeeded"}' >"$output"
  printf '200'
fi
MOCK
chmod +x "$TMP/bin/curl"
export PATH="$TMP/bin:$PATH" YOOKASSA_SHOP_ID=test YOOKASSA_SECRET_KEY=test
create="$ROOT/src/bin/create-payment.sh"
get="$ROOT/src/bin/get-payment.sh"
result="$(bash "$create" 19 unique-order 1000)"
[[ "$(jq -r .id <<<"$result")" == pay-123 ]]
result="$(bash "$get" pay-123)"
[[ "$(jq -r .status <<<"$result")" == succeeded ]]
if HTTP_CODE=400 bash "$create" 19 unique-order 1000 >"$TMP/stdout" 2>"$TMP/stderr"; then exit 1; else
  [[ $? == 65 ]] && grep -q 'test HTTP failure' "$TMP/stderr"
fi
if HTTP_CODE=500 bash "$get" pay-123 >"$TMP/stdout" 2>"$TMP/stderr"; then exit 1; else
  [[ $? == 75 ]] && grep -q 'test HTTP failure' "$TMP/stderr"
fi
echo 'ok - create/get responses, HTTP error bodies, cleanup traps'
