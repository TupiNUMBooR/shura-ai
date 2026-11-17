#!/usr/bin/env bash
# test-post-message.sh
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
  need_commands mktemp grep cmp curl jq rm date cat
  resolve_script

  TMP_DIR="$(mktemp -d)"
  trap 'rm -rf -- "$TMP_DIR"' EXIT
  mkdir -p "$TMP_DIR/bin"
  create_curl_stub
  printf '%04001d' 0 >"$TMP_DIR/long-text"

  run_test "help works without environment" test_help
  run_test "rejects missing arguments" test_missing_arguments
  run_test "requires MAX_BOT_TOKEN" test_requires_token
  run_test "rejects invalid chat ID" test_requires_recipient
  run_test "rejects empty and long text" test_invalid_text
  run_test "posts formatted code block and prints its mid" test_success
  run_test "escapes HTML special characters" test_html_escaping
  run_test "reports curl failure" test_curl_failure
  run_test "reports request timeout" test_timeout
  run_test "reports unauthorized response" test_unauthorized
  run_test "reports retryable HTTP response" test_retryable_http
  run_test "reports non-retryable HTTP response" test_non_retryable_http
  run_test "rejects response without message mid" test_missing_mid

  printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
  ((FAIL == 0))
}

# region tests

test_help() {
  run env -u MAX_BOT_TOKEN "$SCRIPT_UNDER_TEST" --help

  assert_status 0
  assert_stdout_contains "Usage:"
  assert_stdout_contains "MAX_BOT_TOKEN"
  assert_stderr_empty
}

test_missing_arguments() {
  run env MAX_BOT_TOKEN=test "$SCRIPT_UNDER_TEST"

  assert_status 2
  assert_stderr_contains "Expected chat_id"
}

test_requires_token() {
  run env -u MAX_BOT_TOKEN "$SCRIPT_UNDER_TEST" "-123"

  assert_status 78
  assert_stderr_contains "MAX_BOT_TOKEN is required"
}

test_requires_recipient() {
  run env MAX_BOT_TOKEN=test "$SCRIPT_UNDER_TEST" "limit=10"

  assert_status 2
  assert_stderr_contains "Invalid chat_id"
}

test_invalid_text() {
  run run_api "-123" </dev/null

  assert_status 65
  assert_stderr_contains "Invalid message text"

  run run_api "-123" <"$TMP_DIR/long-text"

  assert_status 65
  assert_stderr_contains "Invalid message text"
}

test_success() {
  setup_curl '{"message":{"body":{"mid":"mid-456"}}}'
  TEST_MAX_API_URL="https://max.example/v1/"
  run run_api "-81322498078826" <<<"Hello MAX"

  assert_status 0
  assert_stdout_equals "mid-456"
  assert_stderr_empty
  assert_curl_arg "--request"
  assert_curl_arg "POST"
  assert_curl_arg "Authorization: test-token"
  assert_curl_arg "Content-Type: application/json"
  assert_curl_arg "https://max.example/v1/messages?chat_id=-81322498078826"
  assert_curl_body_equals_text "<pre>Hello MAX</pre>"
}

test_html_escaping() {
  setup_curl '{"message":{"body":{"mid":"mid-456"}}}'
  run run_api "123" <<<'<x> & "quoted" ```'
  assert_status 0
  assert_curl_body_equals_text '<pre>&lt;x&gt; &amp; "quoted" ```</pre>'
}

test_curl_failure() {
  setup_curl '{"error":"network down"}' 7 000
  run run_api "123" <<<"Hello MAX"

  assert_status 69
  assert_stderr_contains "MAX request failed (curl exit 7)"
  assert_stdout_empty
}

test_timeout() {
  setup_curl '{"error":"timeout"}' 28 000
  run run_api "123" <<<"Hello MAX"

  assert_status 75
  assert_stderr_contains "MAX request timed out"
  assert_stdout_empty
}

test_unauthorized() {
  setup_curl '{"error":"unauthorized"}' 0 401
  run run_api "123" <<<"Hello MAX"

  assert_status 78
  assert_stderr_contains "MAX HTTP 401"
  assert_stdout_empty
}

test_retryable_http() {
  setup_curl '{"error":"busy"}' 0 429
  run run_api "123" <<<"Hello MAX"

  assert_status 75
  assert_stderr_contains "MAX HTTP 429"
  assert_stdout_empty
}

test_non_retryable_http() {
  setup_curl '{"error":"bad request"}' 0 400
  run run_api "123" <<<"Hello MAX"

  assert_status 65
  assert_stderr_contains "MAX HTTP 400"
  assert_stdout_empty
}

test_missing_mid() {
  setup_curl '{"message":{"body":{}}}' 0 200
  run run_api "123" <<<"Hello MAX"

  assert_status 65
  assert_stderr_contains "MAX returned no message.body.mid"
  assert_stdout_empty
}

# endregion

# region test helpers

# Locate the script under test by removing the "test-" filename prefix.
# 1. Prefer a sibling: scripts/test-foo.sh -> scripts/foo.sh.
# 2. Otherwise mirror the directory beneath test/ into src/:
#      project/test/test-foo.sh     -> project/src/foo.sh
#      project/test/api/test-foo.sh -> project/src/api/foo.sh
# Resolve relative to this test file, never to the working directory.
# Keep this lookup in tests derived from this template; do not hardcode paths.
resolve_script() {
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
  case "$1" in
    --output|-o)
      output_file="$2"
      shift 2
      ;;
    --data-binary)
      printf '%s' "$2" >"$CURL_REQUEST_FILE"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
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

run_api() {
  env \
    MAX_BOT_TOKEN="${TEST_MAX_BOT_TOKEN:-test-token}" \
    MAX_API_URL="${TEST_MAX_API_URL:-https://max.example}" \
    VERBOSE="${TEST_VERBOSE:-0}" \
    "$SCRIPT_UNDER_TEST" "$@"
}

setup_curl() {
  printf '%s\n' "$1" >"$TMP_DIR/response.json"
  export PATH="$TMP_DIR/bin:$PATH"
  export CURL_ARGS_FILE="$TMP_DIR/curl-args"
  export CURL_REQUEST_FILE="$TMP_DIR/curl-request"
  export CURL_RESPONSE_FILE="$TMP_DIR/response.json"
  export CURL_EXIT="${2:-0}"
  export CURL_HTTP_CODE="${3:-200}"
}

assert_curl_arg() {
  local expected="$1"

  grep -Fxq -- "$expected" "$CURL_ARGS_FILE" \
    || fail "curl arguments do not contain: $expected"
}

assert_curl_body_equals_text() {
  local expected_text="$1"

  jq -S -n --arg text "$expected_text" '{text: $text, format: "html"}' >"$TMP_DIR/expected-body.json"
  jq -S . "$CURL_REQUEST_FILE" >"$TMP_DIR/actual-body.json" \
    || fail "curl request body is not valid JSON"
  cmp -s "$TMP_DIR/expected-body.json" "$TMP_DIR/actual-body.json" \
    || fail "curl request body did not contain the expected text"
}

assert_status() {
  local expected="$1"

  [[ "$STATUS" -eq "$expected" ]] \
    || fail "expected exit $expected, got $STATUS\nstderr:\n$(cat "$STDERR_FILE")"
}

assert_stdout_equals() {
  local expected="$1"

  printf '%s\n' "$expected" | cmp -s - "$STDOUT_FILE" \
    || fail "stdout mismatch\nexpected: $expected\nactual:   $(cat "$STDOUT_FILE")"
}

assert_stdout_empty() {
  [[ ! -s "$STDOUT_FILE" ]] \
    || fail "stdout is not empty:\n$(cat "$STDOUT_FILE")"
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
    command -v "$cmd" &>/dev/null || missing_commands+=("$cmd")
  done

  ((${#missing_commands[@]} == 0)) \
    || error "Missing commands: ${missing_commands[*]}"
}

# endregion

main "$@"
