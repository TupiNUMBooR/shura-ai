#!/usr/bin/env bash
# test-process-outbox.sh
set -euo pipefail

TEST_NAME="$(basename "$0")"
SCRIPT_NAME="${TEST_NAME#test-}"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT=""

PASS=0
FAIL=0
TMP_DIR=""

main() {
  need_commands bash cat date find head mkdir mktemp sort
  resolve_script

  TMP_DIR="$(mktemp -d)"
  trap 'rm -rf -- "$TMP_DIR"' EXIT
  mkdir -p "$TMP_DIR/bin"

  cat >"$TMP_DIR/bin/post-message" <<'EOF_POST_MESSAGE'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$1" >>"$POST_CALLS_FILE"
cat >>"$POST_BODIES_FILE"
[[ "${POST_FAIL:-0}" == 0 ]] || exit 1
printf '%s\n' "${POST_MID:-mid-test}"
EOF_POST_MESSAGE
  chmod +x "$TMP_DIR/bin/post-message"

  export DB_DIR="$TMP_DIR/db"
  export POST_MESSAGE="$TMP_DIR/bin/post-message"
  export POST_CALLS_FILE="$TMP_DIR/post-calls"
  export POST_BODIES_FILE="$TMP_DIR/post-bodies"
  : >"$POST_CALLS_FILE"
  : >"$POST_BODIES_FILE"

  check "rejects arguments" 2 "Unexpected arguments" \
    "$SCRIPT" unexpected

  mkdir -p "$DB_DIR/users"
  check "does nothing when outbox is empty" 0 "" "$SCRIPT"
  check "does not call the sender for empty outbox" 0 "" \
    file_empty "$POST_CALLS_FILE"

  mkdir -p "$DB_DIR/users/42/outbox" "$DB_DIR/users/7/outbox"
  printf 'first message\n' >"$DB_DIR/users/42/outbox/001.txt"
  printf 'second message\n' >"$DB_DIR/users/42/outbox/002.txt"
  printf 'later message\n' >"$DB_DIR/users/7/outbox/001.txt"

  check "sends the first queued message" 0 "Sent to 42" \
    "$SCRIPT"
  check "uses the message owner as recipient" 0 "user_id=42" \
    cat "$POST_CALLS_FILE"
  check "passes the message body to the sender" 0 "first message" \
    cat "$POST_BODIES_FILE"
  check "removes the sent message" 0 "" \
    file_absent "$DB_DIR/users/42/outbox/001.txt"
  check "leaves other queued messages" 0 "second message" \
    cat "$DB_DIR/users/42/outbox/002.txt"

  POST_FAIL=1
  export POST_FAIL
  check "keeps the message when sending fails" 75 "Failed to send to 42" \
    "$SCRIPT"
  check "failed message remains queued" 0 "second message" \
    cat "$DB_DIR/users/42/outbox/002.txt"

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

file_absent() { [[ ! -e "$1" ]]; }
file_empty() { [[ ! -s "$1" ]]; }

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
