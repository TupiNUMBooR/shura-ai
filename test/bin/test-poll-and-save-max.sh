#!/usr/bin/env bash
# test-poll-and-save-max.sh
set -euo pipefail

TEST_NAME="$(basename "$0")"
SCRIPT_NAME="${TEST_NAME#test-}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT=""

PASS=0
FAIL=0
TMP_DIR=""

main() {
  need_commands env date curl jq mktemp mkdir chmod mv rm dirname cat grep
  resolve_script

  TMP_DIR="$(mktemp -d)"
  trap 'rm -rf -- "$TMP_DIR"' EXIT
  mkdir -p "$TMP_DIR/bin"
  create_curl_stub

  check "help works without token" 0 "Usage:" \
    env -u MAX_BOT_TOKEN "$SCRIPT" --help

  check "rejects unexpected arguments" 2 "Unexpected arguments" \
    env "$SCRIPT" extra

  TEST_DB_DIR="$TMP_DIR/db"
  setup_curl '{"updates":[],"marker":17}'
  check "polls MAX and saves marker" 0 "Polling completed: marker=17" \
    run_script
  check "persists polling marker" 0 "17" cat "$TEST_DB_DIR/max/marker.txt"
  check "sends default poll timeout" 0 "timeout=30" \
    grep -F "timeout=30" "$CURL_ARGS_FILE"

  TEST_DB_DIR="$TMP_DIR/invalid-db"
  setup_curl '{"updates":[{"update_type":"message_created","message":{"sender":{"user_id":42},"body":{"seq":4,"text":"old"}}},{"update_type":"message_created","message":{"sender":{"user_id":42},"body":{"seq":8,"text":"new"}}},{"update_type":"message_created","message":{"sender":{"user_id":7},"body":{"seq":2,"text":"hello"}}},{"update_type":"message_read","message":{"sender":{"user_id":9},"body":{"seq":1,"text":"ignore"}}},{"update_type":"message_created","message":{"sender":{"user_id":"abc"},"body":{"seq":3,"text":"bad"}}}]}'
  check "rejects invalid message data" 65 "Invalid user_id or seq" \
    run_script

  TEST_DB_DIR="$TMP_DIR/db"
  mkdir -p "$TEST_DB_DIR/max/users/42"
  printf '5\n' >"$TEST_DB_DIR/max/users/42/last_seq.txt"
  setup_curl '{"updates":[{"update_type":"message_created","message":{"sender":{"user_id":42},"body":{"seq":4,"text":"old"}}},{"update_type":"message_created","message":{"sender":{"user_id":42},"body":{"seq":8,"text":"new"}}},{"update_type":"message_created","message":{"sender":{"user_id":7},"body":{"seq":2,"text":"hello"}}},{"update_type":"message_read","message":{"sender":{"user_id":9},"body":{"seq":1,"text":"ignore"}}},{"update_type":"message_created","message":{"sender":{"user_id":null},"body":{"seq":1,"text":"ignore"}}},{"update_type":"message_created","message":{"sender":{"user_id":9},"body":{}}}],"marker":23}'
  check "saves valid messages and advances marker" 0 "Polling completed: marker=23" \
    run_script
  check "passes previous marker to poller" 0 "marker=17" \
    grep -F "marker=17" "$CURL_ARGS_FILE"
  check "stores newest sequence for user 42" 0 "8" \
    cat "$TEST_DB_DIR/max/users/42/last_seq.txt"
  check "stores newest message contents" 0 "new" \
    jq -r '.message.body.text' "$TEST_DB_DIR/max/users/42/inbox/8.json"
  check "does not store older sequence" 0 "absent" \
    file_is_absent "$TEST_DB_DIR/max/users/42/inbox/4.json"
  check "stores other users independently" 0 "2" \
    cat "$TEST_DB_DIR/max/users/7/last_seq.txt"
  check "ignores non-created updates" 0 "absent" \
    file_is_absent "$TEST_DB_DIR/max/users/9"
  check "updates marker after saving messages" 0 "23" \
    cat "$TEST_DB_DIR/max/marker.txt"

  setup_curl '{"updates":[],"marker":null}' 7
  check "propagates poll failure" 69 "MAX API request failed" \
    run_script

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

run_script() {
  env \
    MAX_BOT_TOKEN=test-token \
    MAX_POLL_TIMEOUT="${TEST_MAX_POLL_TIMEOUT:-30}" \
    DB_DIR="$TEST_DB_DIR" \
    VERBOSE=1 \
    PATH="$TMP_DIR/bin:$PATH" \
    "$SCRIPT"
}

setup_curl() {
  printf '%s\n' "$1" >"$TMP_DIR/curl-response.json"
  export CURL_ARGS_FILE="$TMP_DIR/curl-args"
  export CURL_RESPONSE_FILE="$TMP_DIR/curl-response.json"
  export CURL_EXIT="${2:-0}"
}

create_curl_stub() {
  cat >"$TMP_DIR/bin/curl" <<'EOF_CURL'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$@" >"$CURL_ARGS_FILE"
[[ "${CURL_EXIT:-0}" == 0 ]] || exit "$CURL_EXIT"
cat "$CURL_RESPONSE_FILE"
EOF_CURL
  chmod +x "$TMP_DIR/bin/curl"
}

file_is_absent() {
  [[ ! -e "$1" ]] || return 1
  printf 'absent\n'
}

need_commands() {
  local cmd
  for cmd in "$@"; do
    command -v "$cmd" &>/dev/null || { echo "Missing command: $cmd" >&2; exit 127; }
  done
}

# endregion

main "$@"
