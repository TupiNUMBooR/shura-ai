#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
for test in "$SCRIPT_DIR"/test-*.sh "$SCRIPT_DIR"/bin/test-*.sh; do
  bash "$test"
done
