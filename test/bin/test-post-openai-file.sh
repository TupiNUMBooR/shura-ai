#!/usr/bin/env bash
# test-post-openai-file.sh - Minimal tests for OpenAI file upload.
set -euo pipefail

TEST_NAME="$(basename "$0")"
SCRIPT_NAME="${TEST_NAME#test-}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT=""
PASS=0
FAIL=0
TMP_DIR=""

main() {
  need_commands env curl jq date mktemp rm chmod grep
  resolve_script

  TMP_DIR="$(mktemp -d)"
  trap 'rm -rf -- "$TMP_DIR"' EXIT
  mkdir -p "$TMP_DIR/bin"
  printf 'file contents\n' > "$TMP_DIR/input.bin"
  cat > "$TMP_DIR/bin/curl" <<'EOF_CURL'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$MOCK_ARGS_FILE"
if [[ "${MOCK_EXIT:-0}" != 0 ]]; then
  printf '%s\n' "${MOCK_RESPONSE:-{}}"
  exit "$MOCK_EXIT"
fi
printf '%s\n' "${MOCK_RESPONSE:-{\"id\":\"file_123\"}}"
EOF_CURL
  chmod +x "$TMP_DIR/bin/curl"
  export PATH="$TMP_DIR/bin:$PATH" MOCK_ARGS_FILE="$TMP_DIR/args"

  check "requires API key" 1 "OPENAI_API_KEY" env -u OPENAI_API_KEY "$SCRIPT" "$TMP_DIR/input.bin"
  check "requires file argument" 2 "Expected file path" env OPENAI_API_KEY=test "$SCRIPT"
  check "rejects missing file" 2 "Cannot read file" env OPENAI_API_KEY=test "$SCRIPT" "$TMP_DIR/missing"
  check "uploads file" 0 'file_123' env OPENAI_API_KEY=test "$SCRIPT" "$TMP_DIR/input.bin"
  check_error_body
  check "rejects invalid response" 1 "Invalid upload response" env OPENAI_API_KEY=test MOCK_RESPONSE='{"error":"no id"}' "$SCRIPT" "$TMP_DIR/input.bin"

  grep -Fqx -- 'purpose=vision' "$TMP_DIR/args" || { echo 'Missing purpose=vision' >&2; ((FAIL += 1)); }
  grep -Fqx -- '--fail-with-body' "$TMP_DIR/args" || { echo 'Missing --fail-with-body' >&2; ((FAIL += 1)); }
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

check_error_body() {
  local status=0
  env OPENAI_API_KEY=test MOCK_EXIT=22 MOCK_RESPONSE='{"error":{"message":"quota exceeded"}}' \
    "$SCRIPT" "$TMP_DIR/input.bin" >"$TMP_DIR/stdout" 2>"$TMP_DIR/stderr" || status=$?

  if [[ "$status" == 1 && ! -s "$TMP_DIR/stdout" ]] &&
     grep -Fq 'quota exceeded' "$TMP_DIR/stderr"; then
    echo "ok - logs HTTP error body to stderr"
    ((PASS += 1))
  else
    echo "not ok - logs HTTP error body to stderr"
    cat "$TMP_DIR/stderr" >&2
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
