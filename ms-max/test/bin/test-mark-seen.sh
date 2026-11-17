#!/usr/bin/env bash
# test-mark-seen.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="${SCRIPT_DIR%/test/bin}/src/bin/mark-seen.sh"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf -- "$TMP_DIR"' EXIT
mkdir -p "$TMP_DIR/bin"

cat >"$TMP_DIR/bin/curl" <<'EOF_CURL'
#!/usr/bin/env bash
printf '%s\n' "$@" >"$CURL_ARGS"
if [[ -n "${API_RESPONSE:-}" ]]; then printf '%s\n' "$API_RESPONSE"; else printf '%s\n' '{"success":true}'; fi
exit "${CURL_EXIT:-0}"
EOF_CURL
chmod +x "$TMP_DIR/bin/curl"
export PATH="$TMP_DIR/bin:$PATH"
export CURL_ARGS="$TMP_DIR/args"
export MAX_BOT_TOKEN=secret
export MAX_API_URL=https://max.example

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

"$SCRIPT" -81322498078826 || fail 'successful action'
grep -Fq 'https://max.example/chats/-81322498078826/actions' "$CURL_ARGS" || fail 'chat endpoint'
grep -Fq '{"action":"mark_seen"}' "$CURL_ARGS" || fail 'action payload'

if "$SCRIPT" not-a-number 2>/dev/null; then fail 'invalid chat ID accepted'; fi
if API_RESPONSE='{"success":false}' "$SCRIPT" 123; then fail 'false response accepted'; fi
if CURL_EXIT=22 "$SCRIPT" 123; then fail 'failed request accepted'; fi

printf '4 passed, 0 failed\n'
