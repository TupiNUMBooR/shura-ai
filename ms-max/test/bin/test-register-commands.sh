#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"
cat >"$TMP/bin/curl" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
output=""
while (($#)); do
  case "$1" in
    --output) output="$2"; shift 2 ;;
    --data) printf '%s\n' "$2" >"$REQUEST_JSON"; shift 2 ;;
    *) shift ;;
  esac
done
[[ -z "$output" ]] || printf '%s' '{"error":"test"}' >"$output"
printf '%s' "${HTTP_CODE:-200}"
MOCK
chmod +x "$TMP/bin/curl"
export PATH="$TMP/bin:$PATH" MAX_BOT_TOKEN=test REQUEST_JSON="$TMP/request.json"
script="$ROOT/src/bin/register-commands.sh"
bash "$script" >/dev/null
jq -e '[.commands[].name] == ["start","help","buy","credits"]' "$REQUEST_JSON" >/dev/null
if HTTP_CODE=400 bash "$script" >"$TMP/out" 2>"$TMP/err"; then exit 1; else
  [[ $? == 65 ]] && grep -q '"error":"test"' "$TMP/err"
fi
echo 'ok - registers commands, validates payload and HTTP error body'
