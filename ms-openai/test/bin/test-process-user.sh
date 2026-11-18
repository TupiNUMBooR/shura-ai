#!/usr/bin/env bash
# test-process-user.sh - Tests for per-user request processing.
set -euo pipefail

TEST_NAME="$(basename "$0")"
SCRIPT_NAME="${TEST_NAME#test-}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT=""
PASS=0
FAIL=0
TMP_DIR=""

main() {
  need_commands env jq mktemp mkdir chmod rm cat grep find
  resolve_script
  TMP_DIR="$(mktemp -d)"
  trap 'rm -rf -- "$TMP_DIR"' EXIT
  create_fixtures

  check "requires UID_DIR argument" 2 "Usage:" env "$SCRIPT"
  check "requires inbox directory" 66 "Inbox not found" \
    env "$SCRIPT" "$TMP_DIR/missing"
  mkdir -p "$TMP_DIR/invalid-config/inbox"
  check "rejects invalid credit multiplier" 65 "Invalid CREDITS_PER_USD" \
    env CREDITS_PER_USD=0 "$SCRIPT" "$TMP_DIR/invalid-config"

  setup_user funded
  printf 'user prompt' >"$USER_DIR/inbox/pending.txt"
  check "posts request and charges credits" 0 'AI 000001 completed: 1 credits, $0.000001' \
    env \
      PROCESS_INBOX="$TMP_DIR/process-inbox" POST_RESPONSES="$TMP_DIR/post-responses" \
      CALCULATE_TEXT_COST="$TMP_DIR/text-cost" REQUEST_CAPTURE="$TMP_DIR/request.json" \
      "$SCRIPT" "$USER_DIR"
  assert_json "$TMP_DIR/request.json" '.model == "gpt-6-luna"' "includes agent model"
  assert_file_contains "$TMP_DIR/request.json" 'hello from user' "includes user history"
  assert_file_contains "$USER_DIR/outbox" 'the answer' "writes assistant text to outbox"
  [[ -f "$USER_DIR/outbox/typing" ]] || { echo "not ok - creates typing"; ((FAIL += 1)); }
  [[ ! -f "$USER_DIR/outbox/typing" ]] || { echo "ok - creates typing"; ((PASS += 1)); }
  assert_file_contains "$USER_DIR/ai/000001_a.json" 'the answer' "saves assistant history"
  assert_json "$USER_DIR"/archive/*_operation.json '.credits == 1' "archives operation with charged credits"
  assert_file_contains "$USER_DIR/credits_spent.txt" "1" "updates user credit balance"

  setup_user no_credits
  printf '0\n' >"$USER_DIR/credits_received.txt"
  printf 'queued message' >"$USER_DIR/inbox/queued.txt"
  check "defers inbox when credits are exhausted" 0 "No credits: deferred inbox" \
    env \
      "$SCRIPT" "$USER_DIR"
  assert_file_contains "$USER_DIR/outbox" 'Кредиты закончились' "notifies user about exhausted credits"
  assert_empty_dir "$USER_DIR/inbox" "moves deferred message out of inbox"
  assert_file_contains "$USER_DIR/inbox-delayed/queued.txt" 'queued message' "preserves deferred message"

  setup_user pending_no_credits
  printf '0\n' >"$USER_DIR/credits_received.txt"
  mkdir -p "$USER_DIR/ai"
  printf '%s\n' '{"role":"user","content":"already prepared"}' >"$USER_DIR/ai/000001_u.json"
  check "answers prepared history despite exhausted credits" 0 "AI 000001 completed" \
    env \
      POST_RESPONSES="$TMP_DIR/post-responses" CALCULATE_TEXT_COST="$TMP_DIR/text-cost" \
      REQUEST_CAPTURE="$TMP_DIR/pending-request.json" "$SCRIPT" "$USER_DIR"
  assert_file_contains "$TMP_DIR/pending-request.json" 'already prepared' "sends prepared history to API"
  assert_file_contains "$USER_DIR/ai/000001_a.json" 'the answer' "saves answer for prepared history"
  assert_file_contains "$USER_DIR/outbox" 'Кредиты закончились' "notifies after balance is exhausted by answer"

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

create_fixtures() {
  cat >"$TMP_DIR/process-inbox" <<'EOF_PROCESS_INBOX'
#!/usr/bin/env bash
set -euo pipefail
uid_dir="$1"
mkdir -p "$uid_dir/ai"
printf '%s\n' '{"role":"user","content":"hello from user"}' >"$uid_dir/ai/000001_u.json"
rm -f "$uid_dir/inbox"/*
EOF_PROCESS_INBOX
  cat >"$TMP_DIR/post-responses" <<'EOF_POST_RESPONSES'
#!/usr/bin/env bash
set -euo pipefail
cat >"$REQUEST_CAPTURE"
printf '%s\n' '{"status":"completed","model":"test-model","usage":{"input_tokens":1,"output_tokens":1},"output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"the answer"}]}]}'
EOF_POST_RESPONSES
  cat >"$TMP_DIR/text-cost" <<'EOF_TEXT_COST'
#!/usr/bin/env bash
printf '%s\n' '0.000001'
EOF_TEXT_COST
  chmod +x "$TMP_DIR/process-inbox" "$TMP_DIR/post-responses" "$TMP_DIR/text-cost"
}

setup_user() {
  USER_DIR="$TMP_DIR/user-$1"
  mkdir -p "$USER_DIR/inbox"
  printf '10\n' >"$USER_DIR/credits_received.txt"
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

assert_file_contains() {
  local path="$1" expected="$2" name="$3"
  if [[ -f "$path" ]]; then
    if [[ -d "$path" ]]; then
      if grep -Fq -- "$expected" "$path"/* 2>/dev/null; then
        echo "ok - $name"
        ((PASS += 1))
        return
      fi
    elif grep -Fq -- "$expected" "$path"; then
      echo "ok - $name"
      ((PASS += 1))
      return
    fi
  elif [[ -d "$path" ]] && grep -Fq -- "$expected" "$path"/* 2>/dev/null; then
    echo "ok - $name"
    ((PASS += 1))
    return
  fi
  echo "not ok - $name"
  ((FAIL += 1))
}

assert_json() {
  local file="$1" expression="$2" name="$3"
  if jq -e "$expression" "$file" >/dev/null 2>&1; then
    echo "ok - $name"
    ((PASS += 1))
  else
    echo "not ok - $name"
    ((FAIL += 1))
  fi
}

assert_empty_dir() {
  local dir="$1" name="$2"
  if [[ -z "$(find "$dir" -mindepth 1 -print -quit)" ]]; then
    echo "ok - $name"
    ((PASS += 1))
  else
    echo "not ok - $name"
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
