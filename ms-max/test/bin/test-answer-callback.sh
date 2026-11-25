#!/usr/bin/env bash
# test-answer-callback.sh - Tests for MAX callback notifications.
set -euo pipefail

TEST_NAME="$(basename "$0")"
SCRIPT_NAME="${TEST_NAME#test-}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT=""

PASS=0
FAIL=0
TMP_DIR=""

main() {
  need_commands bash basename cat chmod curl date dirname env grep jq mkdir mktemp rm
  resolve_script

  TMP_DIR=$(mktemp -d)
  trap 'rm -rf -- "$TMP_DIR"' EXIT
  mkdir -p "$TMP_DIR/bin"
  create_curl_stub
  export PATH="$TMP_DIR/bin:$PATH" CURL_ARGS_FILE="$TMP_DIR/curl-args" CURL_BODY_FILE="$TMP_DIR/curl-body"

  check 'requires callback ID' 2 'Expected callback_id' env MAX_BOT_TOKEN=test "$SCRIPT"
  check 'requires MAX_BOT_TOKEN' 78 'MAX_BOT_TOKEN is required' env -u MAX_BOT_TOKEN "$SCRIPT" cb-1
  check 'rejects blank notification' 65 'Expected notification text' env MAX_BOT_TOKEN=test "$SCRIPT" cb-1 <<<" "
  check 'accepts HTTP 200' 0 '' env MAX_BOT_TOKEN=test "$SCRIPT" cb-1 <<<"Готово"
  check 'accepts HTTP 204' 0 '' env MAX_BOT_TOKEN=test MAX_API_URL=https://example.com/ \
    CURL_HTTP_CODE=204 "$SCRIPT" 'cb&1=+' <<<"Готово 💜"
  check 'uses the answers endpoint with an encoded ID' 0 '' \
    grep -Fxq 'https://example.com/answers?callback_id=cb%261%3D%2B' "$CURL_ARGS_FILE"
  check 'uses POST' 0 '' grep -Fxq POST "$CURL_ARGS_FILE"
  check 'sends authorization' 0 '' grep -Fxq 'Authorization: test' "$CURL_ARGS_FILE"
  check 'sends notification JSON' 0 '' jq -e '. == {notification:"Готово 💜"}' "$CURL_BODY_FILE"
  check 'reports HTTP error details' 65 'MAX callback HTTP 400: {"error":"invalid callback"}' \
    env MAX_BOT_TOKEN=test CURL_HTTP_CODE=400 "$SCRIPT" cb-1 <<<"Готово"
  check 'reports curl failure' 69 'MAX callback request failed' \
    env MAX_BOT_TOKEN=test CURL_EXIT=7 "$SCRIPT" cb-1 <<<"Готово"

  printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
  ((FAIL == 0))
}

# region functions

resolve_script() {
  SCRIPT="$SCRIPT_DIR/$SCRIPT_NAME"
  [[ -e "$SCRIPT" ]] && return 0
  [[ "$SCRIPT_DIR" =~ ^(.*)/test(/.*)?$ ]] || return 1
  SCRIPT="${BASH_REMATCH[1]}/src${BASH_REMATCH[2]}/$SCRIPT_NAME"
}

create_curl_stub() {
  cat >"$TMP_DIR/bin/curl" <<'EOF_CURL'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${CURL_EXIT:-0}" != 0 ]]; then exit "$CURL_EXIT"; fi
printf '%s\n' "$@" >"$CURL_ARGS_FILE"
while (($#)); do
  case "$1" in
    --output) printf '%s' '{"error":"invalid callback"}' >"$2"; shift 2 ;;
    --data-binary) printf '%s' "$2" >"$CURL_BODY_FILE"; shift 2 ;;
    *) shift ;;
  esac
done
printf '%s' "${CURL_HTTP_CODE:-200}"
EOF_CURL
  chmod +x "$TMP_DIR/bin/curl"
}

check() {
  local name="$1" expected="$2" contains="$3"
  shift 3
  local output status
  if output="$("$@" 2>&1)"; then status=0; else status=$?; fi
  if [[ "$status" == "$expected" && "$output" == *"$contains"* ]]; then
    echo "ok - $name"
    ((PASS += 1))
  else
    echo "not ok - $name (exit $status, expected $expected)"
    printf '%s\n' "$output" >&2
    ((FAIL += 1))
  fi
}

need_commands() {
  local cmd
  for cmd in "$@"; do
    command -v "$cmd" &>/dev/null || { echo "Missing command: $cmd" >&2; exit 127; }
  done
}

# endregion

main "$@"
