#!/usr/bin/env bash
# test-process-inbox.sh - Tests for inbox message processing.
set -euo pipefail

TEST_NAME="$(basename "$0")"
SCRIPT_NAME="${TEST_NAME#test-}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT=""
PASS=0
FAIL=0
TMP_DIR=""

main() {
  need_commands env jq mktemp mkdir chmod rm cat grep find wc
  resolve_script
  TMP_DIR="$(mktemp -d)"
  trap 'rm -rf -- "$TMP_DIR"' EXIT
  create_stubs

  check "requires UID_DIR argument" 2 "Usage:" env "$SCRIPT"
  check "requires inbox directory" 66 "Inbox not found" env "$SCRIPT" "$TMP_DIR/missing"

  setup_user text
  printf 'hello Shura\n' >"$USER_DIR/inbox/001.txt"
  check "processes text message into user history" 0 "User user-text completed: 1m 1t 0i 0a" \
    env "$SCRIPT" "$USER_DIR"
  assert_json "$USER_DIR/ai/000001_u.json" '.role == "user" and .content == "hello Shura"' "stores text message"
  assert_no_files "$USER_DIR/inbox" "removes processed inbox message"
  assert_file_exists "$USER_DIR/outbox/seen_001" "creates seen only when AI consumes message"
  setup_user batch
  printf 'one' >"$USER_DIR/inbox/110.txt"
  printf '' >"$USER_DIR/inbox/111.txt"
  printf 'image bytes' >"$USER_DIR/inbox/111.png"
  printf '' >"$USER_DIR/inbox/112.txt"
  printf 'audio bytes' >"$USER_DIR/inbox/112.ogg"
  check "summarizes entire batch and history range" 0 \
    "User user-batch completed: 3m 1t 1i 1a, inbox/ 110-112, ai/ 000001-000003" \
    env TRANSCRIBE="$TMP_DIR/transcribe" POST_FILE="$TMP_DIR/post-file" \
      CALCULATE_AUDIO_COST="$TMP_DIR/audio-cost" "$SCRIPT" "$USER_DIR"

  setup_user multimodal
  printf 'What is in this picture?\n' >"$USER_DIR/inbox/002.txt"
  printf 'audio bytes' >"$USER_DIR/inbox/002.ogg"
  printf 'image bytes' >"$USER_DIR/inbox/002.PNG"
  check "transcribes audio and uploads image" 0 "User user-multimodal completed: 1m 1t 1i 1a" \
    env TRANSCRIBE="$TMP_DIR/transcribe" POST_FILE="$TMP_DIR/post-file" \
      CALCULATE_AUDIO_COST="$TMP_DIR/audio-cost" "$SCRIPT" "$USER_DIR"
  assert_file_contains "$USER_DIR/ai/000001_u.json" 'Recognized speech' "adds transcription to user content"
  assert_json "$USER_DIR/ai/000001_u.json" '[.content[]? | select(.type == "input_image" and .file_id == "file_test")] | length == 1' "adds uploaded image ID"
  assert_json "$USER_DIR/operation.json" '.transcriptions[0].usd == 0.0045' "records transcription cost"
  assert_one_file "$USER_DIR/archive" '*_transcriptions_response.json' "archives transcription response"

  setup_user unsupported
  printf 'look at this\n' >"$USER_DIR/inbox/003.txt"
  printf 'data' >"$USER_DIR/inbox/003.xyz"
  check "rejects unsupported attachment" 65 "Unsupported attachment" env "$SCRIPT" "$USER_DIR"
  [[ -f "$USER_DIR/inbox/003.txt" ]] || fail "unsupported message should remain in inbox"
  assert_file_exists "$USER_DIR/outbox/seen_003" "marks message as taken even on processing error"

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

create_stubs() {
  cat >"$TMP_DIR/transcribe" <<'EOF_TRANSCRIBE'
#!/usr/bin/env bash
printf '%s\n' '{"text":"Recognized speech"}'
EOF_TRANSCRIBE
  cat >"$TMP_DIR/post-file" <<'EOF_POST_FILE'
#!/usr/bin/env bash
printf '%s\n' '{"id":"file_test"}'
EOF_POST_FILE
  cat >"$TMP_DIR/audio-cost" <<'EOF_AUDIO_COST'
#!/usr/bin/env bash
printf '%s\n' '0.00450000'
EOF_AUDIO_COST
  chmod +x "$TMP_DIR/transcribe" "$TMP_DIR/post-file" "$TMP_DIR/audio-cost"
}

setup_user() {
  USER_DIR="$TMP_DIR/user-$1"
  mkdir -p "$USER_DIR/inbox"
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

assert_file_exists() {
  if [[ -f "$1" ]]; then echo "ok - $2"; ((PASS += 1));
  else echo "not ok - $2"; ((FAIL += 1)); fi
}

assert_file_contains() {
  local file="$1" expected="$2" name="$3"
  if [[ -f "$file" ]] && grep -Fq -- "$expected" "$file"; then
    echo "ok - $name"
    ((PASS += 1))
  else
    echo "not ok - $name"
    [[ ! -f "$file" ]] || cat "$file" >&2
    ((FAIL += 1))
  fi
}

assert_json() {
  local file="$1" expression="$2" name="$3"
  if jq -e "$expression" "$file" >/dev/null 2>&1; then
    echo "ok - $name"
    ((PASS += 1))
  else
    echo "not ok - $name"
    [[ ! -f "$file" ]] || cat "$file" >&2
    ((FAIL += 1))
  fi
}

assert_no_files() {
  local dir="$1" name="$2"
  if [[ -z "$(find "$dir" -maxdepth 1 -type f -print -quit)" ]]; then
    echo "ok - $name"
    ((PASS += 1))
  else
    echo "not ok - $name"
    ((FAIL += 1))
  fi
}

assert_one_file() {
  local dir="$1" pattern="$2" name="$3"
  if [[ "$(find "$dir" -maxdepth 1 -type f -name "$pattern" | wc -l)" -eq 1 ]]; then
    echo "ok - $name"
    ((PASS += 1))
  else
    echo "not ok - $name"
    ((FAIL += 1))
  fi
}

fail() { echo "not ok - $*" >&2; ((FAIL += 1)); }

need_commands() {
  local cmd
  for cmd in "$@"; do
    command -v "$cmd" &>/dev/null || { echo "Missing command: $cmd" >&2; exit 127; }
  done
}

# endregion

main "$@"
