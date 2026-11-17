#!/usr/bin/env bash
# test-calculate-audio-cost.sh - Tests for audio cost calculation.
set -euo pipefail

TEST_NAME="$(basename "$0")"
SCRIPT_NAME="${TEST_NAME#test-}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT=""

PASS=0
FAIL=0

main() {
  need_commands env jq
  resolve_script

  check "requires model argument" 2 "Usage:" \
    env "$SCRIPT" <<< '{"usage":{"type":"duration","seconds":60}}'

  check "rejects extra arguments" 2 "Usage:" \
    env "$SCRIPT" gpt-transcribe extra <<< '{"usage":{"type":"duration","seconds":60}}'

  check "calculates duration cost" 0 "0.00450000" \
    env "$SCRIPT" gpt-transcribe <<< '{"usage":{"type":"duration","seconds":60}}'

  check "calculates zero duration" 0 "0.00000000" \
    env "$SCRIPT" gpt-transcribe <<< '{"usage":{"type":"duration","seconds":0}}'

  check "rejects unknown model" 5 "Unknown model: missing" \
    env "$SCRIPT" missing <<< '{"usage":{"type":"duration","seconds":60}}'

  check "rejects invalid duration usage" 5 "Invalid audio usage or price" \
    env "$SCRIPT" gpt-transcribe <<< '{"usage":{"type":"tokens","seconds":60}}'

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

need_commands() {
  local cmd
  for cmd in "$@"; do
    command -v "$cmd" &>/dev/null || { echo "Missing command: $cmd" >&2; exit 127; }
  done
}

# endregion

main "$@"
