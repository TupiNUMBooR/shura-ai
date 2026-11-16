#!/usr/bin/env bash
# test-transcribe-openai.sh
set -euo pipefail

TEST_NAME="$(basename "$0")"
SCRIPT_NAME="${TEST_NAME#test-}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT=""

PASS=0
FAIL=0
TMP_DIR=""

main() {
  need_commands env date curl jq mktemp mkdir chmod rm grep cat
  resolve_script

  TMP_DIR="$(mktemp -d)"
  trap 'rm -rf -- "$TMP_DIR"' EXIT
  mkdir -p "$TMP_DIR/bin"
  create_curl_stub
  printf 'audio data' >"$TMP_DIR/audio.ogg"

  check "help works without API key" 0 "Usage:" \
    env -u OPENAI_API_KEY "$SCRIPT" --help

  check "requires audio file argument" 2 "Expected audio file" \
    env OPENAI_API_KEY=test "$SCRIPT"

  check "requires API key" 78 "OPENAI_API_KEY is required" \
    env -u OPENAI_API_KEY "$SCRIPT" "$TMP_DIR/audio.ogg"

  check "rejects missing audio file" 66 "Cannot read audio file" \
    env OPENAI_API_KEY=test "$SCRIPT" "$TMP_DIR/missing.ogg"

  setup_curl '{"text":"recognized words"}'
  check "transcribes audio and logs when verbose" 0 "recognized words" \
    env OPENAI_API_KEY=test-key \
      OPENAI_ENDPOINT_URL=https://openai.example/transcriptions \
      OPENAI_TRANSCRIBE_MODEL=test-model VERBOSE=1 \
      PATH="$TMP_DIR/bin:$PATH" \
      "$SCRIPT" "$TMP_DIR/audio.ogg"

  check "sends API key" 0 "Authorization: Bearer test-key" \
    grep -F "Authorization: Bearer test-key" "$CURL_ARGS_FILE"
  check "uploads selected audio file" 0 "file=@$TMP_DIR/audio.ogg" \
    grep -F "file=@$TMP_DIR/audio.ogg" "$CURL_ARGS_FILE"
  check "sends selected model" 0 "model=test-model" \
    grep -F "model=test-model" "$CURL_ARGS_FILE"
  check "requests JSON response" 0 "response_format=json" \
    grep -F "response_format=json" "$CURL_ARGS_FILE"
  check "uses configured endpoint" 0 "https://openai.example/transcriptions" \
    grep -F "https://openai.example/transcriptions" "$CURL_ARGS_FILE"

  setup_curl '{"text":42}'
  check "rejects invalid API response" 65 "Invalid transcription response" \
    env OPENAI_API_KEY=test PATH="$TMP_DIR/bin:$PATH" \
      "$SCRIPT" "$TMP_DIR/audio.ogg"

  setup_curl '{"error":"unavailable"}' 22
  check "reports curl failure" 69 "Transcription request failed" \
    env OPENAI_API_KEY=test PATH="$TMP_DIR/bin:$PATH" \
      "$SCRIPT" "$TMP_DIR/audio.ogg"

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

setup_curl() {
  printf '%s\n' "$1" >"$TMP_DIR/curl-response.json"
  export CURL_ARGS_FILE="$TMP_DIR/curl-args"
  export CURL_RESPONSE_FILE="$TMP_DIR/curl-response.json"
  export CURL_EXIT="${2:-0}"
}

need_commands() {
  local cmd
  for cmd in "$@"; do
    command -v "$cmd" &>/dev/null || { echo "Missing command: $cmd" >&2; exit 127; }
  done
}

# endregion

main "$@"
