#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
passed=0; failed=0
while IFS= read -r test; do
  echo "==> ${test##*/}" >&2
  if bash "$test" >&2; then ((passed+=1)); else ((failed+=1)); fi
done < <(find "$SCRIPT_DIR" -name 'test-*.sh' -type f | sort)
echo "$passed test files passed, $failed failed" >&2
((failed==0))
