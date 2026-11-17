#!/usr/bin/env bash
# test-calculate-text-cost.sh - Tests for text cost calculation.
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

  check "rejects malformed response JSON" 4 "parse error" \
    env "$SCRIPT" <<<'{'

  check "rejects unexpected arguments" 2 "Usage:" \
    env "$SCRIPT" extra <<< '{}'

  check "calculates uncached input and output cost" 0 "0.00060000" \
    env "$SCRIPT" <<< '{"model":"gpt-6-luna","usage":{"input_tokens":1000,"output_tokens":1000}}'

  check "calculates cached and cache write costs" 0 "0.00001115" \
    env "$SCRIPT" <<< '{"model":"gpt-6-luna","usage":{"input_tokens":10,"output_tokens":20,"input_tokens_details":{"cached_tokens":2,"cache_write_tokens":3,"cache_write_tokens_details":{"ttl_30m_tokens":1,"ttl_12h_tokens":2}}}}'

  check "rejects unknown model" 5 "Unknown model: missing" \
    env "$SCRIPT" <<< '{"model":"missing","usage":{"input_tokens":0,"output_tokens":0}}'

  check "rejects invalid usage totals" 5 "Invalid usage or prices" \
    env "$SCRIPT" <<< '{"model":"gpt-6-luna","usage":{"input_tokens":2,"output_tokens":0,"input_tokens_details":{"cached_tokens":3}}}'

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
