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
while (($#)); do
  if [[ "$1" == "-o" ]]; then
    shift
    printf 'fake image' >"$1"
  fi
  shift
done
printf 'image/jpeg'
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
  printf '%s\n' '{"credits":{"received":2500,"spent":1867}}' >"$DB_DIR/users/42/user.json"
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
  check "handles start and help" 0 "Received: 2m 2t" bash "$SCRIPT"
  check "start includes balance" 0 "Баланс: 633 кредитов" cat "$DB_DIR/users/42/outbox/110.txt"
  check "help includes commands" 0 "/reset — очистить историю" cat "$DB_DIR/users/42/outbox/111.txt"
  check "start bypasses AI inbox" 0 "" file_absent "$DB_DIR/users/42/inbox/110.txt"
  check "help bypasses AI inbox" 0 "" file_absent "$DB_DIR/users/42/inbox/111.txt"

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
  check "retries successfully" 0 "" bash "$SCRIPT"
  check "publishes recovered message" 0 "broken" \
    cat "$DB_DIR/users/7/inbox/200.txt"

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
