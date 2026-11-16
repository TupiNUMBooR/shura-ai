#!/usr/bin/env bash
# run-tests.sh
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

mapfile -t tests < <(find "$SCRIPT_DIR" -type f -name 'test-*.sh' | sort)

passed=0
failed=0

for test_file in "${tests[@]}"; do
  printf '\n==> %s\n' "${test_file#"$SCRIPT_DIR/"}" >&2

  if bash "$test_file" >&2; then
    ((passed += 1))
  else
    ((failed += 1))
  fi
done

printf '\n%d test files passed, %d failed\n' "$passed" "$failed" >&2

((failed == 0))
