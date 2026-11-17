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
  need_commands bash cat chmod cmp date find head jq mkdir mktemp mv rm sort tr wc
  resolve_script

  TMP_DIR="$(mktemp -d)"
  trap 'rm -rf -- "$TMP_DIR"' EXIT
  mkdir -p "$TMP_DIR/bin"

  cat >"$TMP_DIR/bin/post-message" <<'EOF_POST_MESSAGE'
#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' "$1" >>"$POST_CALLS_FILE"
attempt=$(wc -l <"$POST_CALLS_FILE")
body="$POST_PARTS_DIR/$attempt"
cat >"$body"

jq -eRs 'length <= 3500' <"$body" >/dev/null || exit 1

[[ "${POST_FAIL:-0}" == 0 ]] || exit 1
(( attempt > ${POST_FAIL_UNTIL:-0} )) || exit 1
(( ${POST_FAIL_FROM:-0} == 0 || attempt < POST_FAIL_FROM )) || exit 1

cat "$body" >>"$POST_BODIES_FILE"
printf '%s\n' "${POST_MID:-mid-test}"
EOF_POST_MESSAGE
  chmod +x "$TMP_DIR/bin/post-message"

  export DB_DIR="$TMP_DIR/db"
  export POST_MESSAGE="$TMP_DIR/bin/post-message"
  export POST_CALLS_FILE="$TMP_DIR/post-calls"
  export POST_BODIES_FILE="$TMP_DIR/post-bodies"
  export POST_PARTS_DIR="$TMP_DIR/parts"

  mkdir -p "$POST_PARTS_DIR"
  reset_sender

  check "rejects arguments" 2 "Unexpected arguments" \
    "$SCRIPT" unexpected

  check "handles missing users directory" 0 "" "$SCRIPT"

  mkdir -p "$DB_DIR/users"
  check "does nothing when outbox is empty" 0 "" "$SCRIPT"
  check "does not call sender for empty outbox" 0 "" \
    file_empty "$POST_CALLS_FILE"

  mkdir -p "$DB_DIR/users/42/outbox" "$DB_DIR/users/7/outbox"
  printf 'first message\n' >"$DB_DIR/users/42/outbox/001.txt"
  printf 'second message\n' >"$DB_DIR/users/42/outbox/002.txt"
  printf 'later message\n' >"$DB_DIR/users/7/outbox/001.txt"

  check "sends first queued message" 0 "Sent to 42" "$SCRIPT"
  check "uses message owner as recipient" 0 "user_id=42" \
    cat "$POST_CALLS_FILE"
  check "passes message body" 0 "first message" \
    cat "$POST_BODIES_FILE"
  check "removes sent message" 0 "" \
    file_absent "$DB_DIR/users/42/outbox/001.txt"
  check "leaves other messages queued" 0 "second message" \
    cat "$DB_DIR/users/42/outbox/002.txt"

  export POST_FAIL=1
  reset_sender

  check "moves message after three failures" 0 "outbox-failed" \
    "$SCRIPT"
  check "attempts sending three times" 0 "3" \
    count_lines "$POST_CALLS_FILE"
  check "removes failed message from outbox" 0 "" \
    file_absent "$DB_DIR/users/42/outbox/002.txt"
  check "preserves failed message" 0 "second message" \
    cat "$DB_DIR/users/42/outbox-failed/002.txt"
  check "leaves other users untouched" 0 "later message" \
    cat "$DB_DIR/users/7/outbox/001.txt"

  unset POST_FAIL
  export POST_FAIL_UNTIL=2
  reset_sender

  check "succeeds on third attempt" 0 "Sent to 7" "$SCRIPT"
  check "makes exactly three attempts" 0 "3" \
    count_lines "$POST_CALLS_FILE"
  check "removes message after third-attempt success" 0 "" \
    file_absent "$DB_DIR/users/7/outbox/001.txt"

  unset POST_FAIL_UNTIL
  reset_sender

  mkdir -p "$DB_DIR/users/invalid/outbox"
  printf 'invalid recipient\n' >"$DB_DIR/users/invalid/outbox/001.txt"

  check "rejects invalid user ID" 0 "outbox-failed" "$SCRIPT"
  check "does not send to invalid ID" 0 "" \
    file_empty "$POST_CALLS_FILE"
  check "preserves invalid recipient message" 0 "invalid recipient" \
    cat "$DB_DIR/users/invalid/outbox-failed/001.txt"

  # Long message: multiple parts, no data loss.
  reset_sender
  local long="$DB_DIR/users/42/outbox/long.txt"
  local original="$TMP_DIR/original.txt"
  local padding

  printf -v padding '%*s' 8000 ''
  padding="${padding// /x}"
  printf '%s\n%s\n%s' "$padding" 'Привет 🌙💜' 'Конец.' >"$long"
  cp "$long" "$original"

  check "splits long message" 0 "Sent to 42" "$SCRIPT"
  check "sends multiple parts" 0 "3" \
    count_lines "$POST_CALLS_FILE"
  check "preserves full Unicode text" 0 "" \
    cmp "$original" "$POST_BODIES_FILE"
  check "removes fully sent message" 0 "" \
    file_absent "$long"
  check "each part fits 3500 characters" 0 "" \
    parts_fit

  # Failure after first successful part.
  reset_sender
  export POST_FAIL_FROM=2

  printf -v padding '%*s' 7000 ''
  padding="${padding// /x}"
  printf '%s' "$padding" >"$long"

  check "stops after partial delivery failure" 0 "outbox-failed" \
    "$SCRIPT"
  check "retries failed part three times" 0 "4" \
    count_lines "$POST_CALLS_FILE"
  check "moves remaining text to failed queue" 0 "" \
    file_absent "$long"
  check "preserves only unsent remainder" 0 "3500" \
    char_count "$DB_DIR/users/42/outbox-failed/long.txt"
  check "records only successful delivery" 0 "3500" \
    char_count "$POST_BODIES_FILE"

  unset POST_FAIL_FROM
  reset_sender

  # Empty file should not generate a message.
  : >"$DB_DIR/users/42/outbox/empty.txt"

  check "handles empty message" 0 "" "$SCRIPT"
  check "does not send empty message" 0 "" \
    file_empty "$POST_CALLS_FILE"
  check "removes empty message" 0 "" \
    file_absent "$DB_DIR/users/42/outbox/empty.txt"

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

reset_sender() {
  : >"$POST_CALLS_FILE"
  : >"$POST_BODIES_FILE"
  rm -f -- "$POST_PARTS_DIR"/*
}

parts_fit() {
  local part
  for part in "$POST_PARTS_DIR"/*; do
    jq -eRs 'length <= 3500' <"$part" >/dev/null || return 1
  done
}

file_absent() { [[ ! -e "$1" ]]; }
file_empty() { [[ ! -s "$1" ]]; }
count_lines() { wc -l <"$1" | tr -d ' '; }
char_count() { jq -Rs 'length' <"$1"; }

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
