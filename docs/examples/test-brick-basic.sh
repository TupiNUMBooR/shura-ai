#!/usr/bin/env bash
# test-brick-basic.sh - Minimal tests for a Bash brick.
set -euo pipefail

TEST_NAME="$(basename "$0")"
SCRIPT_NAME="${TEST_NAME#test-}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT=""
PASS=0
FAIL=0

main() (
  need_commands env date sleep mktemp cat rm
  resolve_script

  local stderr_file
  stderr_file="$(mktemp)"
  trap 'rm -f -- "$stderr_file"' EXIT

  check "requires HOME" 1 "" "HOME" \
    env -u HOME "$SCRIPT" hello

  check "requires argument" 2 "" "Expected argument" \
    env HOME=/example "$SCRIPT"

  check "runs successfully" 0 '$HOME=/example, $1=hello' "Sleeping for 0 seconds" \
    env HOME=/example SLEEP_SECONDS=0 "$SCRIPT" hello

  printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
  ((FAIL == 0))
)

# region functions

resolve_script() {
  SCRIPT="$SCRIPT_DIR/$SCRIPT_NAME"
  [[ -e "$SCRIPT" ]] && return 0

  [[ "$SCRIPT_DIR" =~ ^(.*)/test(/.*)?$ ]] || return 1
  SCRIPT="${BASH_REMATCH[1]}/src${BASH_REMATCH[2]}/$SCRIPT_NAME"
}

check() {
  local name="$1" expected="$2" expected_stdout="$3" expected_stderr="$4"
  shift 4

  local stdout stderr status
  if stdout="$("$@" 2>"$stderr_file")"; then status=0; else status=$?; fi
  stderr="$(cat "$stderr_file")"

  if [[ "$status" == "$expected" && "$stdout" == "$expected_stdout" && "$stderr" == *"$expected_stderr"* ]]; then
    echo "ok - $name"
    ((PASS += 1))
  else
    echo "not ok - $name (exit $status, expected $expected)"
    printf 'stdout: %s\nstderr: %s\n' "$stdout" "$stderr" >&2
    ((FAIL += 1))
  fi
}

need_commands() {
  local cmd missing=()
  for cmd; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
  done
  ((${#missing[@]} == 0)) || error "Missing commands: ${missing[*]}"
}

# endregion

main "$@"
