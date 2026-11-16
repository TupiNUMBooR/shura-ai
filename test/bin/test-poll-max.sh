#!/usr/bin/env bash
# test-poll-max.sh
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
  need_commands mktemp grep cmp curl jq rm date cat
  resolve_script

  TMP_DIR="$(mktemp -d)"
  trap 'rm -rf -- "$TMP_DIR"' EXIT
  mkdir -p "$TMP_DIR/bin"
  create_curl_stub

  run_test "help works without environment" test_help
  run_test "rejects extra arguments" test_extra_arguments
  run_test "requires MAX_BOT_TOKEN" test_requires_token
  run_test "rejects invalid marker" test_invalid_marker
  run_test "rejects invalid poll timeout" test_invalid_timeout
  run_test "polls without marker and returns raw JSON" test_success_without_marker
  run_test "sends marker, custom endpoint, and timeout" test_success_with_marker
  run_test "reports curl failure" test_curl_failure
  run_test "rejects invalid API response" test_invalid_response
  run_test "logs details in verbose mode" test_verbose

  printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
  ((FAIL == 0))
}

# region tests

test_help() {
  run env -u MAX_BOT_TOKEN "$SCRIPT_UNDER_TEST" --help

  assert_status 0
  assert_stdout_contains "Usage:"
  assert_stdout_contains "MAX_POLL_TIMEOUT"
  assert_stderr_empty
}

test_extra_arguments() {
  run env MAX_BOT_TOKEN=test "$SCRIPT_UNDER_TEST" 123 extra

  assert_status 2
  assert_stderr_contains "Expected zero or one marker argument"
}

test_requires_token() {
  run env -u MAX_BOT_TOKEN "$SCRIPT_UNDER_TEST"

  assert_status 78
  assert_stderr_contains "MAX_BOT_TOKEN is required"
}

test_invalid_marker() {
  run run_api "abc123"

  assert_status 2
  assert_stderr_contains "Marker must be a non-negative integer"
  assert_stdout_empty
}

test_invalid_timeout() {
  TEST_MAX_POLL_TIMEOUT="-1"
  run run_api

  assert_status 78
  assert_stderr_contains "MAX_POLL_TIMEOUT must be an integer from 0 to 90"

  TEST_MAX_POLL_TIMEOUT="91"
  run run_api

  assert_status 78
  assert_stderr_contains "MAX_POLL_TIMEOUT must be an integer from 0 to 90"

  TEST_MAX_POLL_TIMEOUT="1.5"
  run run_api

  assert_status 78
  assert_stderr_contains "MAX_POLL_TIMEOUT must be an integer from 0 to 90"
}

test_success_without_marker() {
  setup_curl '{"updates":[],"marker":null}'
  run run_api

  assert_status 0
  cmp -s "$TMP_DIR/response.json" "$STDOUT_FILE" \
    || fail "response JSON was not printed unchanged"
  assert_stderr_empty
  assert_curl_arg "--get"
  assert_curl_arg "--fail"
  assert_curl_arg "Authorization: test-token"
  assert_curl_arg "timeout=30"
  assert_curl_arg "https://platform-api2.max.ru/updates"
  assert_curl_arg "--max-time"
  assert_curl_arg "45"
  assert_curl_arg_not "marker="
}

test_success_with_marker() {
  setup_curl '{"updates":[{"update_id":1}],"marker":123}'
  TEST_MAX_ENDPOINT_URL="https://max.example/custom-updates"
  TEST_MAX_POLL_TIMEOUT="0"
  run run_api "123"

  assert_status 0
  cmp -s "$TMP_DIR/response.json" "$STDOUT_FILE" \
    || fail "response JSON was not printed unchanged"
  assert_stderr_empty
  assert_curl_arg "marker=123"
  assert_curl_arg "timeout=0"
  assert_curl_arg "https://max.example/custom-updates"
  assert_curl_arg "15"
}

test_curl_failure() {
  setup_curl '{"error":"network down"}' 7
  run run_api

  assert_status 69
  assert_stderr_contains "MAX API request failed"
  assert_stdout_empty
}

test_invalid_response() {
  setup_curl '{"updates":{},"marker":null}'
  run run_api

  assert_status 70
  assert_stderr_contains "Invalid MAX API response"
  assert_stdout_empty
}

test_verbose() {
  setup_curl '{"updates":[],"marker":null}'
  TEST_VERBOSE=1
  run run_api

  assert_status 0
  assert_stderr_contains "Polling MAX: timeout=30 marker=none"
  cmp -s "$TMP_DIR/response.json" "$STDOUT_FILE" \
    || fail "verbose log leaked into stdout or changed the response"
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
[[ "${CURL_EXIT:-0}" == 0 ]] || exit "$CURL_EXIT"
cat "$CURL_RESPONSE_FILE"
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
    MAX_ENDPOINT_URL="${TEST_MAX_ENDPOINT_URL:-https://platform-api2.max.ru/updates}" \
    MAX_POLL_TIMEOUT="${TEST_MAX_POLL_TIMEOUT:-30}" \
    VERBOSE="${TEST_VERBOSE:-0}" \
    "$SCRIPT_UNDER_TEST" "$@"
}

setup_curl() {
  printf '%s\n' "$1" >"$TMP_DIR/response.json"
  export PATH="$TMP_DIR/bin:$PATH"
  export CURL_ARGS_FILE="$TMP_DIR/curl-args"
  export CURL_RESPONSE_FILE="$TMP_DIR/response.json"
  export CURL_EXIT="${2:-0}"
}

assert_curl_arg() {
  local expected="$1"

  grep -Fxq -- "$expected" "$CURL_ARGS_FILE" \
    || fail "curl arguments do not contain: $expected"
}

assert_curl_arg_not() {
  local unexpected="$1"

  ! grep -Fq -- "$unexpected" "$CURL_ARGS_FILE" \
    || fail "curl arguments unexpectedly contain: $unexpected"
}

assert_status() {
  local expected="$1"

  [[ "$STATUS" -eq "$expected" ]] \
    || fail "expected exit $expected, got $STATUS\nstderr:\n$(cat "$STDERR_FILE")"
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
