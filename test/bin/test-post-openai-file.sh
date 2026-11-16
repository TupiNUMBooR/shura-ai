#!/usr/bin/env bash
# test-post-openai-file.sh
set -Eeuo pipefail

TEST_NAME="$(basename "$0")"
SCRIPT_NAME="${TEST_NAME#test-}"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_UNDER_TEST=""

PASS=0
FAIL=0
TMP_DIR=""
STDOUT_FILE=""
STDERR_FILE=""
STATUS=0

main() {
  # Test helpers plus external commands required by the script under test.
  need_commands mktemp grep cmp curl jq rm
  resolve_script

  TMP_DIR="$(mktemp -d)"
  trap 'rm -rf -- "$TMP_DIR"' EXIT
  mkdir -p "$TMP_DIR/bin"
  create_curl_stub
  : >"$TMP_DIR/input.bin"

  run_test "help works without environment" test_help
  run_test "help rejects extra arguments" test_help_extra_arguments
  run_test "rejects invalid argument count" test_argument_count
  run_test "requires API key" test_missing_api_key
  run_test "rejects missing input file" test_missing_file
  run_test "uploads file and prints raw JSON" test_success
  run_test "reports curl failure" test_curl_failure
  run_test "reports non-2xx status" test_http_failure
  run_test "rejects invalid API response" test_invalid_response

  printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
  ((FAIL == 0))
}

# region tests

test_help() {
  run env -u OPENAI_API_KEY "$SCRIPT_UNDER_TEST" --help
  assert_status 0
  assert_stdout_contains "Usage:"
  assert_stdout_contains "OPENAI_API_KEY"
  assert_stderr_empty
}

test_help_extra_arguments() {
  run "$SCRIPT_UNDER_TEST" --help extra
  assert_status 2
  assert_stderr_contains "Help accepts no additional arguments"
}

test_argument_count() {
  run env OPENAI_API_KEY=test "$SCRIPT_UNDER_TEST"
  assert_status 2
  assert_stderr_contains "Expected exactly one file path"
}

test_missing_api_key() {
  run env -u OPENAI_API_KEY "$SCRIPT_UNDER_TEST" "$TMP_DIR/input.bin"
  assert_status 78
  assert_stderr_contains "OPENAI_API_KEY is required"
}

test_missing_file() {
  run env OPENAI_API_KEY=test "$SCRIPT_UNDER_TEST" "$TMP_DIR/no-file"
  assert_status 66
  assert_stderr_contains "File missing or unreadable"
}

test_success() {
  setup_curl '{"id":"file_123","object":"file","error":null}'
  run env OPENAI_API_KEY=test PATH="$PATH" CURL_ARGS_FILE="$CURL_ARGS_FILE" CURL_RESPONSE_FILE="$CURL_RESPONSE_FILE" CURL_EXIT=0 CURL_HTTP_CODE=200 "$SCRIPT_UNDER_TEST" "$TMP_DIR/input.bin"

  assert_status 0
  cmp -s "$TMP_DIR/response.json" "$STDOUT_FILE" \
    || fail "response JSON was not printed unchanged"
  grep -Fq -- 'Authorization: Bearer test' "$CURL_ARGS_FILE" \
    || fail "authorization header was not sent"
  grep -Fq -- 'purpose=vision' "$CURL_ARGS_FILE" \
    || fail "purpose was not sent"
  grep -Fq -- "file=@$TMP_DIR/input.bin" "$CURL_ARGS_FILE" \
    || fail "input file was not sent"
  grep -Fq -- 'expires_after[seconds]=2592000' "$CURL_ARGS_FILE" \
    || fail "expiration was not sent"
  assert_stderr_empty
}

test_curl_failure() {
  setup_curl '{"message":"network down"}' 7 000
  run env OPENAI_API_KEY=test PATH="$PATH" CURL_ARGS_FILE="$CURL_ARGS_FILE" CURL_RESPONSE_FILE="$CURL_RESPONSE_FILE" CURL_EXIT=7 CURL_HTTP_CODE=000 "$SCRIPT_UNDER_TEST" "$TMP_DIR/input.bin"

  assert_status 69
  assert_stderr_contains "Upload failed"
  assert_stdout_empty
}

test_http_failure() {
  setup_curl '{"error":"denied"}' 0 401
  run env OPENAI_API_KEY=test PATH="$PATH" CURL_ARGS_FILE="$CURL_ARGS_FILE" CURL_RESPONSE_FILE="$CURL_RESPONSE_FILE" CURL_EXIT=0 CURL_HTTP_CODE=401 "$SCRIPT_UNDER_TEST" "$TMP_DIR/input.bin"

  assert_status 69
  assert_stderr_contains "HTTP 401"
  assert_stdout_empty
}

test_invalid_response() {
  setup_curl '{"object":"file"}' 0 200
  run env OPENAI_API_KEY=test PATH="$PATH" CURL_ARGS_FILE="$CURL_ARGS_FILE" CURL_RESPONSE_FILE="$CURL_RESPONSE_FILE" CURL_EXIT=0 CURL_HTTP_CODE=200 "$SCRIPT_UNDER_TEST" "$TMP_DIR/input.bin"

  assert_status 65
  assert_stderr_contains "Invalid upload response"
  assert_stdout_empty
}

# endregion

# region test helpers

resolve_script() {
  # Locate the script under test by removing the "test-" filename prefix.
  # 1. Prefer a sibling: scripts/test-foo.sh -> scripts/foo.sh.
  # 2. Otherwise mirror the directory beneath test/ into src/:
  #      project/test/test-foo.sh     -> project/src/foo.sh
  #      project/test/api/test-foo.sh -> project/src/api/foo.sh
  # Resolve relative to this test file, never to the working directory.
  # Keep this lookup in tests derived from this template; do not hardcode paths.
  local local_script="$SCRIPT_DIR/$SCRIPT_NAME"

  if [[ -e "$local_script" ]]; then
    SCRIPT_UNDER_TEST="$local_script"
  else
    local dir="$SCRIPT_DIR" relative_dir=""

    while [[ "$dir" != / && "${dir##*/}" != test ]]; do
      relative_dir="/${dir##*/}$relative_dir"
      dir="$(dirname -- "$dir")"
    done

    [[ "${dir##*/}" == test ]] \
      || error "No sibling script and no parent test/ directory: $SCRIPT_NAME"

    SCRIPT_UNDER_TEST="$(dirname -- "$dir")/src$relative_dir/$SCRIPT_NAME"
  fi

  [[ -e "$SCRIPT_UNDER_TEST" ]] \
    || error "Tested file not found: $SCRIPT_UNDER_TEST"
  [[ -x "$SCRIPT_UNDER_TEST" ]] \
    || error "Tested file is not executable: $SCRIPT_UNDER_TEST"
}

create_curl_stub() {
  cat >"$TMP_DIR/bin/curl" <<'EOF_CURL'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s\n' "$@" >"$CURL_ARGS_FILE"
output_file=""
while (($#)); do
  if [[ "$1" == "-o" ]]; then output_file="$2"; shift 2; else shift; fi
done
[[ -n "$output_file" ]] || exit 90
cat "$CURL_RESPONSE_FILE" >"$output_file"
[[ "${CURL_EXIT:-0}" == 0 ]] || exit "$CURL_EXIT"
printf '%s' "${CURL_HTTP_CODE:-200}"
EOF_CURL
  chmod +x "$TMP_DIR/bin/curl"
}

run_test() {
  local name="$1"
  local test_function="$2"

  if ( "$test_function" ); then
    printf 'ok - %s\n' "$name"
    ((PASS += 1))
  else
    printf 'not ok - %s\n' "$name"
    ((FAIL += 1))
  fi
}

run() {
  STDOUT_FILE="$TMP_DIR/stdout"
  STDERR_FILE="$TMP_DIR/stderr"

  if "$@" >"$STDOUT_FILE" 2>"$STDERR_FILE"; then
    STATUS=0
  else
    STATUS=$?
  fi
}

setup_curl() {
  printf '%s\n' "$1" >"$TMP_DIR/response.json"
  export PATH="$TMP_DIR/bin:$PATH"
  export CURL_ARGS_FILE="$TMP_DIR/curl-args"
  export CURL_RESPONSE_FILE="$TMP_DIR/response.json"
  export CURL_EXIT="${2:-0}"
  export CURL_HTTP_CODE="${3:-200}"
}

assert_status() {
  local expected="$1"

  [[ "$STATUS" -eq "$expected" ]] \
    || fail "expected exit $expected, got $STATUS\nstderr:\n$(cat "$STDERR_FILE")"
}

assert_stdout_contains() {
  local expected="$1"

  grep -Fq -- "$expected" "$STDOUT_FILE" \
    || fail "stdout does not contain: $expected"
}

assert_stderr_contains() {
  local expected="$1"

  grep -Fq -- "$expected" "$STDERR_FILE" \
    || fail "stderr does not contain: $expected"
}

assert_stderr_empty() {
  [[ ! -s "$STDERR_FILE" ]] \
    || fail "stderr is not empty:\n$(cat "$STDERR_FILE")"
}

assert_stdout_empty() {
  [[ ! -s "$STDOUT_FILE" ]] \
    || fail "stdout is not empty:\n$(cat "$STDOUT_FILE")"
}

fail() {
  printf '  %b\n' "$*" >&2
  exit 1
}

error() {
  printf '[%s] [ERROR] %s\n' "$TEST_NAME" "$*" >&2
  exit 1
}

need_commands() {
  local cmd
  local -a missing_commands=()

  for cmd in "$@"; do
    command -v "$cmd" >/dev/null 2>&1 || missing_commands+=("$cmd")
  done

  ((${#missing_commands[@]} == 0)) \
    || error "Missing commands: ${missing_commands[*]}"
}

# endregion

main "$@"
