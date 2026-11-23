#!/usr/bin/env bash
# test-receive-messages.sh
set -euo pipefail

TEST_NAME="$(basename "$0")"
SCRIPT_NAME="${TEST_NAME#test-}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

PASS=0
FAIL=0

main() {
  need_commands bash jq curl mktemp
  resolve_script

  TMP_DIR=$(mktemp -d)
  trap 'rm -rf "$TMP_DIR"' EXIT
  mkdir -p "$TMP_DIR/bin"

  cat >"$TMP_DIR/bin/poll" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "${POLL_RESPONSE:?}"
EOF

  cat >"$TMP_DIR/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "${CURL_FAIL:-0}" == 0 ]] || exit 22
output=""; callback=0
while (($#)); do
  case "$1" in
    -o|--output) output="$2"; shift 2 ;;
    --write-out) shift 2 ;;
    *'/answers?callback_id='*) callback=1; shift ;;
    *) shift ;;
  esac
done
if (( callback )); then
  [[ -z "$output" ]] || printf '{"error":"callback mock error"}' >"$output"
  printf '%s' "${CURL_HTTP_CODE:-200}"
else
  [[ -z "$output" ]] || printf 'fake image' >"$output"
  printf '%s' "${CURL_CONTENT_TYPE:-image/jpeg}"
fi
EOF
  chmod +x "$TMP_DIR/bin/"*

  export DB_DIR="$TMP_DIR/db"
  export POLL_MAX="$TMP_DIR/bin/poll"
  export PATH="$TMP_DIR/bin:$PATH"

  check "rejects arguments" 2 "Unexpected arguments" bash "$SCRIPT" extra

  export POLL_RESPONSE='{"marker":10,"updates":[
    {"update_type":"message_created","message":{
      "sender":{"user_id":42},
      "recipient":{"chat_id":-420,"chat_type":"dialog"},
      "body":{"seq":100,"text":"hello","attachments":[]}
    }},
    {"update_type":"message_created","message":{
      "sender":{"user_id":42},
      "recipient":{"chat_id":-420,"chat_type":"dialog"},
      "body":{"seq":101,"text":"photo","attachments":[
        {"type":"image","payload":{"url":"https://example.com/photo"}}
      ]}
    }}
  ]}'

  check "counts messages and media" 0 "Received: 2m 2t 1i" bash "$SCRIPT"
  check "saves text" 0 "hello" cat "$DB_DIR/users/42/inbox/100.txt"
  check "initializes user credits" 0 "1000" cat "$DB_DIR/users/42/credits_received.txt"
  check "leaves spent credits absent" 0 "" file_absent "$DB_DIR/users/42/credits_spent.txt"
  check "saves attachment" 0 "fake image" cat "$DB_DIR/users/42/inbox/101.01.jpg"
  check "saves message with attachment" 0 "photo" cat "$DB_DIR/users/42/inbox/101.txt"
  check "persists MAX chat ID" 0 "-420" cat "$DB_DIR/users/42/max_chat_id.txt"
  check "advances marker" 0 "10" cat "$DB_DIR/marker.txt"
  check "does not create nested max" 0 "" file_absent "$DB_DIR/max"

  export CURL_FAIL=1
  check "skips existing messages" 0 "" bash "$SCRIPT"
  check "does not create seen from incoming message" 0 "" \
    file_absent "$DB_DIR/users/42/outbox/seen_100"

  rm -rf "$DB_DIR"
  mkdir -p "$DB_DIR/users/42"
  printf '2500\n' >"$DB_DIR/users/42/credits_received.txt"
  printf '1867\n' >"$DB_DIR/users/42/credits_spent.txt"
  export POLL_RESPONSE='{"marker":15,"updates":[
    {"update_type":"message_created","message":{
      "sender":{"user_id":42},"recipient":{"chat_id":-420,"chat_type":"dialog"},
      "body":{"seq":110,"text":"/start","attachments":[]}
    }},
    {"update_type":"message_created","message":{
      "sender":{"user_id":42},"recipient":{"chat_id":-420,"chat_type":"dialog"},
      "body":{"seq":111,"text":"/help","attachments":[]}
    }}
  ]}'
  check "handles start and help" 0 "Received: 2m 2c" bash "$SCRIPT"
  check "commands counted separately from text" 0 "Received: 2m 2c" bash "$SCRIPT"
  check "start includes balance" 0 "Баланс: 633 кредитов" cat "$DB_DIR/users/42/outbox/110.txt"
  check "help includes commands" 0 "/reset — очистить историю" cat "$DB_DIR/users/42/outbox/111.txt"
  check "help advertises balance" 0 "/balance — мой баланс" cat "$DB_DIR/users/42/outbox/111.txt"
  check "start bypasses AI inbox" 0 "" file_absent "$DB_DIR/users/42/inbox/110.txt"
  check "help bypasses AI inbox" 0 "" file_absent "$DB_DIR/users/42/inbox/111.txt"

  rm -rf "$DB_DIR/users/99"
  export POLL_RESPONSE='{"marker":15,"updates":[{"update_type":"message_created","message":{
    "sender":{"user_id":99},"recipient":{"chat_id":-990,"chat_type":"dialog"},
    "body":{"seq":115,"text":"/start","attachments":[]}
  }}]}'
  check "new user start initializes before help" 0 "" bash "$SCRIPT"
  check "new user start balance" 0 "Баланс: 1000 кредитов" cat "$DB_DIR/users/99/outbox/115.txt"
  check "new user does not create spent" 0 "" file_absent "$DB_DIR/users/99/credits_spent.txt"

  unset CURL_FAIL
  export POLL_RESPONSE='{"marker":16,"updates":[
    {"update_type":"message_created","message":{
      "sender":{"user_id":42},"recipient":{"chat_id":-420,"chat_type":"dialog"},
      "body":{"seq":112,"text":"/buy","attachments":[]}
    }},
    {"update_type":"message_created","message":{
      "sender":{"user_id":42},"recipient":{"chat_id":-420,"chat_type":"dialog"},
      "body":{"seq":113,"text":"/ololo","attachments":[]}
    }},
    {"update_type":"message_created","message":{
      "sender":{"user_id":42},"recipient":{"chat_id":-420,"chat_type":"dialog"},
      "body":{"seq":114,"text":"/balance","attachments":[]}
    }},
    {"update_type":"message_callback","callback":{
      "user":{"user_id":42},"payload":"buy:5000","callback_id":"cb-1"
    }}
  ]}'
  MAX_PAYMENT_RETURN_URL= check "rejects purchase without return URL" 78 "MAX_PAYMENT_RETURN_URL" bash "$SCRIPT"
  check "does not enqueue purchase without return URL" 0 "" file_absent "$DB_DIR/users/42/payments/orders/5000.json"
  export MAX_PAYMENT_RETURN_URL=https://web.max.ru/829005994
  check "handles purchase and unknown command" 0 "" bash "$SCRIPT"
  check "creates buy keyboard with one callback per row" 0 "" jq -e '
    .buttons | length == 3 and all(.[]; length == 1 and .[0].type == "callback")
    and .[1][0].payload == "buy:5000"
  ' "$DB_DIR/users/42/outbox/message_buy_112.json"
  check "buy shows balance" 0 "" jq -e '.text | contains("633 кредитов")' "$DB_DIR/users/42/outbox/message_buy_112.json"
  check "balance shows remaining credits" 0 "633 кредитов" cat "$DB_DIR/users/42/outbox/114.txt"
  check "balance bypasses AI" 0 "" file_absent "$DB_DIR/users/42/inbox/114.txt"
  check "creates order with package and return URL" 0 "" jq -e --arg url "$MAX_PAYMENT_RETURN_URL" \
    '. == {credits:5000,return_url:$url}' "$DB_DIR/users/42/payments/orders/5000.json"
  check "rejects unknown commands without AI" 0 "Нет такой команды" cat "$DB_DIR/users/42/outbox/113.txt"
  check "unknown command not passed to inbox" 0 "" file_absent "$DB_DIR/users/42/inbox/113.txt"
  MAX_PAYMENT_RETURN_URL=https://max.example/other check "handles repeated purchase click" 0 "" bash "$SCRIPT"
  check "repeated purchase preserves original return URL" 0 "" jq -e --arg url "$MAX_PAYMENT_RETURN_URL" \
    '.return_url == $url' "$DB_DIR/users/42/payments/orders/5000.json"
  export MAX_BOT_TOKEN=test CURL_HTTP_CODE=400
  check "callback shows HTTP error body" 0 "MAX callback HTTP 400: {\"error\":\"callback mock error\"}" bash "$SCRIPT"
  unset MAX_BOT_TOKEN CURL_HTTP_CODE

  export CURL_FAIL=1
  rm -rf "$DB_DIR"
  export POLL_RESPONSE='{"marker":20,"updates":[
    {"update_type":"message_created","message":{
      "sender":{"user_id":7},
      "recipient":{"chat_id":-70,"chat_type":"dialog"},
      "body":{"seq":200,"text":"broken","attachments":[
        {"type":"image","payload":{"url":"https://example.com/photo"}}
      ]}
    }}
  ]}'

  check "fails on download error" 22 "" bash "$SCRIPT"
  check "does not publish incomplete message" 0 "" \
    file_absent "$DB_DIR/users/7/inbox/200.txt"
  check "does not advance marker on failure" 0 "" \
    file_absent "$DB_DIR/marker.txt"

  unset CURL_FAIL
  CURL_CONTENT_TYPE=image/heic check "rejects HEIC" 65 "Unsupported media type: image/heic" bash "$SCRIPT"
  CURL_CONTENT_TYPE=audio/aac check "rejects AAC" 65 "Unsupported media type: audio/aac" bash "$SCRIPT"
  check "does not publish message with unsupported media" 0 "" file_absent "$DB_DIR/users/7/inbox/200.txt"
  check "does not advance marker on unsupported media" 0 "" file_absent "$DB_DIR/marker.txt"

  check "retries successfully" 0 "" bash "$SCRIPT"
  check "publishes recovered message" 0 "broken" \
    cat "$DB_DIR/users/7/inbox/200.txt"
  check "partial initialization survives retry" 0 "1000" cat "$DB_DIR/users/7/credits_received.txt"

  rm -rf "$DB_DIR"
  export POLL_RESPONSE='{"marker":30,"updates":[
    {"update_type":"message_created","message":{
      "sender":{"user_id":42},
      "recipient":{"chat_id":420,"chat_type":"chat"},
      "body":{"seq":300,"text":"group message","attachments":[]}
    }},
    {"update_type":"message_created","message":{
      "sender":{"user_id":43},
      "recipient":{"chat_id":430,"chat_type":"channel"},
      "body":{"seq":301,"text":"channel message","attachments":[]}
    }}
  ]}'

  check "ignores groups and channels" 0 "" bash "$SCRIPT"
  check "does not create group users" 0 "" \
    file_absent "$DB_DIR/users/42"
  check "does not create channel users" 0 "" \
    file_absent "$DB_DIR/users/43"
  check "advances marker for ignored messages" 0 "30" \
    cat "$DB_DIR/marker.txt"

  printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
  ((FAIL == 0))
}

# region functions

resolve_script() {
  SCRIPT="$SCRIPT_DIR/$SCRIPT_NAME"
  [[ -f "$SCRIPT" ]] && return 0
  [[ "$SCRIPT_DIR" =~ ^(.*)/test(/.*)?$ ]] || return 1
  SCRIPT="${BASH_REMATCH[1]}/src${BASH_REMATCH[2]}/$SCRIPT_NAME"
}

check() {
  local name="$1" expected="$2" contains="$3" output status
  shift 3
  if output=$("$@" 2>&1); then status=0; else status=$?; fi
  if [[ "$status" == "$expected" && "$output" == *"$contains"* ]]; then
    echo "ok - $name"
    ((PASS+=1))
  else
    echo "not ok - $name (exit $status, expected $expected)"
    printf '%s\n' "$output" >&2
    ((FAIL+=1))
  fi
}

file_absent() { [[ ! -e "$1" ]]; }

need_commands() {
  local cmd
  for cmd in "$@"; do
    command -v "$cmd" &>/dev/null || {
      echo "Missing command: $cmd" >&2
      exit 127
    }
  done
}

# endregion

main "$@"
