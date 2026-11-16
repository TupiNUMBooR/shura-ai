#!/usr/bin/env bash
# test-bash-brick-example.sh
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
  # Test helpers (mktemp, grep, cmp) plus external commands used by the script (cat, date).
  need_commands mktemp grep cmp cat date
  resolve_script

  TMP_DIR="$(mktemp -d)"
  trap 'rm -rf -- "$TMP_DIR"' EXIT

  run_test "help works without environment" test_help
  run_test "rejects missing arguments" test_missing_arguments
  run_test "requires EXAMPLE_VALUE" test_requires_example_value
  run_test "prints message" test_prints_message

  printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
  ((FAIL == 0))
}

# region tests

test_help() {
  run env -u EXAMPLE_VALUE "$SCRIPT_UNDER_TEST" --help

  assert_status 0
  assert_stdout_contains "Usage:"
  assert_stdout_contains "EXAMPLE_VALUE"
  assert_stderr_empty
}

test_missing_arguments() {
  run env EXAMPLE_VALUE=example "$SCRIPT_UNDER_TEST"

  assert_status 2
  assert_stderr_contains "Expected message"
}

test_requires_example_value() {
  run env -u EXAMPLE_VALUE "$SCRIPT_UNDER_TEST" "hello"

  assert_status 78
  assert_stderr_contains "EXAMPLE_VALUE is required"
}

test_prints_message() {
  run env EXAMPLE_VALUE=example "$SCRIPT_UNDER_TEST" "Hello, world!"

  assert_status 0
  assert_stdout_equals "Hello, world!"
  assert_stderr_empty
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

assert_status() {
  local expected="$1"

  [[ "$STATUS" -eq "$expected" ]] \
    || fail "expected exit $expected, got $STATUS\nstderr:\n$(cat "$STDERR_FILE")"
}

assert_stdout_equals() {
  local expected="$1"
  # Compare bytes, including trailing newlines. The brick prints one line.
  printf '%s\n' "$expected" | cmp -s - "$STDOUT_FILE" \
    || fail "stdout mismatch\nexpected: $expected\nactual:   $(cat "$STDOUT_FILE")"
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
