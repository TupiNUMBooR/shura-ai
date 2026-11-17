#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
export MAX_BOT_TOKEN=test MAX_DEBUG_CHAT_ID=123 MAX_ERROR_CHAT_ID=456
export DB_DIR="$(mktemp -d)"
trap 'rm -rf "$DB_DIR"' EXIT
# shellcheck source=/dev/null
source "$ROOT/src/entrypoint.sh"
mkdir -p "$DB_DIR/queue/debug" "$DB_DIR/queue/error"
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
[[ $(find "$DB_DIR/queue/error" -name '*.txt' | wc -l) == 1 ]]
error_text=$(cat "$DB_DIR"/queue/error/*.txt)
[[ "$error_text" == *'INFO before 1'* ]]
[[ "$error_text" == *'INFO before 2'* ]]
[[ "$error_text" == *'ERROR Connection refused'* ]]
[[ "$error_text" == *'INFO retrying'* ]]
[[ "$error_text" != *'This is a self error'* ]]
flush_debug
[[ $(find "$DB_DIR/queue/debug" -name '*.txt' | wc -l) == 1 ]]
debug_text=$(cat "$DB_DIR"/queue/debug/*.txt)
[[ "$debug_text" == *'[ms-logs] Started'* ]]
[[ "$debug_text" == *'[ms-logs] [ERROR] This is a self error'* ]]
[[ "$debug_text" == *'[ms-max] ERROR Connection refused'* ]]

handle_line other 'WARN slow'
[[ "$INCIDENT_LEVEL" == WARN ]]
handle_line other 'FATAL big failure'
[[ "$INCIDENT_LEVEL" == ERROR ]]
flush_incident

LOG_MAX_CHARS=150
handle_line other "INFO $(printf '%0500d' 0)"
flush_debug
for file in "$DB_DIR"/queue/debug/*.txt "$DB_DIR"/queue/error/*.txt; do
  [[ $(wc -c < "$file") -le 3500 ]]
done
# Escaped HTML must fit into 3500 characters, including <pre> tags.
queue_message debug "$(printf '%01200d' 0 | tr 0 '&')"
for file in "$DB_DIR"/queue/debug/*.txt; do
  encoded=$(jq -Rs '"<pre>" + (gsub("&"; "&amp;") | gsub("<"; "&lt;") | gsub(">"; "&gt;")) + "</pre>" | length' <"$file")
  (( encoded <= 3500 ))
done
printf 'ok - global incident context, self filtering, severity and queues\n' 
