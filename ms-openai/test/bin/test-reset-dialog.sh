#!/usr/bin/env bash
# test-reset-dialog.sh - Tests for the reset dialog brick.
set -euo pipefail

TEST_NAME="$(basename "$0")"
SCRIPT_NAME="${TEST_NAME#test-}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT=""
PASS=0
FAIL=0

main() {
  resolve_script
  local uid_dir
  test_dir="$(mktemp -d)"
  trap 'rm -rf -- "$test_dir"' EXIT
  uid_dir="$test_dir/user"
  mkdir -p "$uid_dir"/{inbox,inbox-delayed,ai,archive,outbox}

  check "requires UID_DIR" 2 "Usage:" "$SCRIPT"
  check "requires a marker" 66 "Reset marker not found" "$SCRIPT" "$uid_dir"

  touch "$uid_dir"/inbox/{9.txt,9.01.ogg,9.reset,10.reset,11.txt}
  touch "$uid_dir"/inbox-delayed/{8.txt,8.01.webp,12.txt}
  touch "$uid_dir"/{ai/000001_u.json,archive/prior.json,operation.json,outbox/previous.txt}
  check "applies reset" 0 "" "$SCRIPT" "$uid_dir"
  check "records the latest numeric seq" 0 "10" cat "$uid_dir/reset_seq.txt"
  check "keeps only newer inbox files" 0 "" bash -c '
    files=("$1"/inbox/* "$1"/inbox-delayed/*)
    [[ ${#files[@]} == 2 && -f "$1/inbox/11.txt" && -f "$1/inbox-delayed/12.txt" ]]
  ' _ "$uid_dir"
  check "clears dialog and keeps archive and outbox" 0 "" bash -c '
    [[ ! -e "$1/ai/000001_u.json" && ! -e "$1/operation.json" &&
       -f "$1/archive/prior.json" && -f "$1/outbox/previous.txt" ]]
  ' _ "$uid_dir"
  check "queues reset notification" 0 "" grep -Fxq 'Начали новый диалог 💜' "$uid_dir"/outbox/*.txt

  touch "$uid_dir"/{ai/000001_u.json,inbox/10.reset}
  check "handles a replayed marker" 0 "" "$SCRIPT" "$uid_dir"
  check "replayed marker preserves new history" 0 "" test -f "$uid_dir/ai/000001_u.json"
  check "replayed marker is removed" 0 "" test ! -e "$uid_dir/inbox/10.reset"

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


# endregion

main "$@"
