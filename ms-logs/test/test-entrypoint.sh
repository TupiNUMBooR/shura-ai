#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
export MAX_BOT_TOKEN=test MAX_DEBUG_CHAT_ID=123 MAX_ALERT_CHAT_ID=456
# shellcheck source=/dev/null
source "$ROOT/src/entrypoint.sh"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf -- "$WORK_DIR"' EXIT
mkdir -p "$WORK_DIR/queue/debug" "$WORK_DIR/queue/error" "$WORK_DIR/queue/success"
SELF_ID=self
NAMES[self]=ms-logs
NAMES[other]=ms-max
LOG_MAX_CHARS=3500
CONTEXT_BEFORE_LINES=2

handle_line self 'Started'
handle_line self '[ERROR] This is a self error'
handle_line other 'INFO before 1'
handle_line other 'INFO before 2'
handle_line other 'ERROR Connection refused'
handle_line other 'INFO retrying'
[[ "$INCIDENT_LEVEL" == ERROR ]]
flush_incident
[[ -z "$INCIDENT_FILE" ]]
[[ $(find "$WORK_DIR/queue/error" -name '*.txt' | wc -l) == 1 ]]
error_text=$(cat "$WORK_DIR"/queue/error/*.txt)
[[ "$error_text" == *'INFO before 1'* ]]
[[ "$error_text" == *'INFO before 2'* ]]
[[ "$error_text" == *'ERROR Connection refused'* ]]
[[ "$error_text" == *'INFO retrying'* ]]
[[ "$error_text" != *'This is a self error'* ]]
flush_debug
[[ $(find "$WORK_DIR/queue/debug" -name '*.txt' | wc -l) == 1 ]]
debug_text=$(cat "$WORK_DIR"/queue/debug/*.txt)
[[ "$debug_text" == *'[ms-logs] Started'* ]]
[[ "$debug_text" == *'[ms-logs] [ERROR] This is a self error'* ]]
[[ "$debug_text" == *'[ms-max] ERROR Connection refused'* ]]

handle_line other 'WARN slow'
[[ "$INCIDENT_LEVEL" == WARN ]]
handle_line other 'FATAL big failure'
[[ "$INCIDENT_LEVEL" == ERROR ]]
flush_incident

handle_line self '[SUCCESS] self event'
handle_line other 'SUCCESS without brackets'
handle_line other '[success] lowercase tag'
handle_line other '[OK] unrelated tag'
handle_line other 'INFO before success'
handle_line other '[SUCCESS] first event'
success_files=("$WORK_DIR"/queue/success/*.txt)
[[ ${#success_files[@]} == 1 && -f "${success_files[0]}" ]]
[[ $(cat "${success_files[0]}") == '[ms-max] [SUCCESS] first event' ]]
handle_line other '[SUCCESS] second event after a failed attempt'
handle_line other 'INFO after success'
success_files=("$WORK_DIR"/queue/success/*.txt)
[[ ${#success_files[@]} == 2 ]]
[[ $(cat "${success_files[1]}") == '[ms-max] [SUCCESS] second event after a failed attempt' ]]
[[ -z "$INCIDENT_FILE" && "$INCIDENT_DEADLINE" == 0 ]]

LOG_MAX_CHARS=150
handle_line other "INFO $(printf '%0500d' 0)"
flush_debug
for file in "$WORK_DIR"/queue/debug/*.txt "$WORK_DIR"/queue/error/*.txt; do
  [[ $(wc -c < "$file") -le 3500 ]]
done
# Escaped HTML must fit into 3500 characters, including <pre> tags.
queue_message debug "$(printf '%01200d' 0 | tr 0 '&')"
for file in "$WORK_DIR"/queue/debug/*.txt; do
  encoded=$(jq -Rs '"<pre>" + (gsub("&"; "&amp;") | gsub("<"; "&lt;") | gsub(">"; "&gt;")) + "</pre>" | length' <"$file")
  (( encoded <= 3500 ))
done
printf 'ok - global incident context, self filtering, severity and success queue\n'

export ALERT_CAPTURE="$WORK_DIR/lifecycle.log"
POST_MESSAGE="$WORK_DIR/post-message"
cat >"$POST_MESSAGE" <<'EOF_POST'
#!/usr/bin/env bash
set -euo pipefail
IFS= read -r message
printf '%s %s\n' "$1" "$message" >>"$ALERT_CAPTURE"
exit "${POST_STATUS:-0}"
EOF_POST
chmod +x "$POST_MESSAGE"

alert_lifecycle "Started VERSION=$VERSION" 2>"$WORK_DIR/start.stderr"
( shutdown ) 2>"$WORK_DIR/stop.stderr"
mapfile -t alerts <"$ALERT_CAPTURE"
[[ ${#alerts[@]} == 2 ]]
[[ "${alerts[0]}" == "456 [ms-logs] $(cat "$WORK_DIR/start.stderr")" && "${alerts[0]}" == *"Started VERSION=$VERSION" ]]
[[ "${alerts[1]}" == "456 [ms-logs] $(cat "$WORK_DIR/stop.stderr")" && "${alerts[1]}" == *"Stopped VERSION=$VERSION" ]]
POST_STATUS=1 alert_lifecycle "Started VERSION=$VERSION" 2>"$WORK_DIR/failed.stderr"
grep -Fq 'Could not send lifecycle alert' "$WORK_DIR/failed.stderr"
printf 'ok - startup and shutdown alerts\n'
