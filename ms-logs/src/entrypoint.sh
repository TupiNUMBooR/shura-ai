#!/usr/bin/env bash
# entrypoint.sh
set -euo pipefail

SCRIPT_NAME="$(basename "$0")"

# required environment
: "${MAX_BOT_TOKEN:?}"
: "${MAX_DEBUG_CHAT_ID:?}"
: "${MAX_ALERT_CHAT_ID:?}"

# optional environment
VERSION="${VERSION:-dev}"
LOG_BATCH_SECONDS="${LOG_BATCH_SECONDS:-60}"
INCIDENT_DELAY_SECONDS="${INCIDENT_DELAY_SECONDS:-1}"
SEND_RETRY_SECONDS="${SEND_RETRY_SECONDS:-3}"
CONTAINER_SCAN_SECONDS="${CONTAINER_SCAN_SECONDS:-1}"
LOG_MAX_CHARS="${LOG_MAX_CHARS:-3500}"
CONTEXT_BEFORE_LINES="${CONTEXT_BEFORE_LINES:-10}"
POST_MESSAGE="${POST_MESSAGE:-/app/bin/post-message.sh}"

WORK_DIR=""
SELF_ID=""
PROJECT_NAME=""
STARTED_AT=""
QUEUE_SEQ=0
DEBUG_TEXT=""
DEBUG_STARTED=0
INCIDENT_FILE=""
INCIDENT_DEADLINE=0
INCIDENT_LEVEL=""
STOPPING=0

declare -A WATCHED=()
declare -A NAMES=()
declare -a RING=()
declare -a CHILD_PIDS=()

main() {
  [[ $# -eq 0 ]] || { printf 'Unexpected arguments\n' >&2; return 2; }
  local v
  for v in "$LOG_BATCH_SECONDS" "$INCIDENT_DELAY_SECONDS" "$SEND_RETRY_SECONDS" "$CONTAINER_SCAN_SECONDS" "$LOG_MAX_CHARS" "$CONTEXT_BEFORE_LINES"; do
    [[ "$v" =~ ^[0-9]+$ ]] || { printf 'Invalid numeric configuration\n' >&2; return 78; }
  done
  (( LOG_BATCH_SECONDS > 0 && INCIDENT_DELAY_SECONDS > 0 && SEND_RETRY_SECONDS > 0 && CONTAINER_SCAN_SECONDS > 0 && LOG_MAX_CHARS >= 100 && CONTEXT_BEFORE_LINES > 0 )) || return 78
  [[ -x "$POST_MESSAGE" ]] || { printf 'post-message.sh not executable\n' >&2; return 78; }

  WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/ms-logs.XXXXXX")
  trap 'rm -rf -- "$WORK_DIR"' EXIT
  mkdir -p "$WORK_DIR/queue/debug" "$WORK_DIR/queue/error" "$WORK_DIR/queue/alert"
  local fifo="$WORK_DIR/stream"
  mkfifo "$fifo"
  exec 3<>"$fifo"
  rm -f -- "$fifo"

  SELF_ID=$(docker inspect --format '{{.Id}}' "${HOSTNAME:-}" 2>/dev/null) || { log 'Cannot inspect own container'; return 1; }
  PROJECT_NAME=$(docker inspect --format '{{ index .Config.Labels "com.docker.compose.project" }}' "$SELF_ID" 2>/dev/null) || return 1
  [[ -n "$PROJECT_NAME" && "$PROJECT_NAME" != '<no value>' ]] || { log 'Compose project label missing'; return 1; }
  STARTED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  send_queue debug "$MAX_DEBUG_CHAT_ID" & CHILD_PIDS+=("$!")
  send_queue error "$MAX_ALERT_CHAT_ID" & CHILD_PIDS+=("$!")
  send_queue alert "$MAX_ALERT_CHAT_ID" & CHILD_PIDS+=("$!")
  trap shutdown TERM INT
  alert_lifecycle '🟢 START' "Started VERSION=$VERSION"

  local next_scan=0 now_us record
  while :; do
    now_us="${EPOCHREALTIME/./}"
    if (( now_us >= next_scan )); then
      watch_new_containers
      next_scan=$((now_us + CONTAINER_SCAN_SECONDS * 1000000))
    fi
    now_us="${EPOCHREALTIME/./}"
    if (( INCIDENT_DEADLINE > 0 && now_us >= INCIDENT_DEADLINE )); then flush_incident; fi
    if (( DEBUG_STARTED > 0 && now_us - DEBUG_STARTED >= LOG_BATCH_SECONDS * 1000000 )); then flush_debug; fi
    if IFS= read -r -t 0.2 -u 3 record; then
      now_us="${EPOCHREALTIME/./}"
      if (( INCIDENT_DEADLINE > 0 && now_us >= INCIDENT_DEADLINE )); then flush_incident; fi
      if (( DEBUG_STARTED > 0 && now_us - DEBUG_STARTED >= LOG_BATCH_SECONDS * 1000000 )); then flush_debug; fi
      handle_record "$record"
    fi
    now_us="${EPOCHREALTIME/./}"
    if (( INCIDENT_DEADLINE > 0 && now_us >= INCIDENT_DEADLINE )); then
      flush_incident
    fi
    if (( DEBUG_STARTED > 0 && now_us - DEBUG_STARTED >= LOG_BATCH_SECONDS * 1000000 )); then
      flush_debug
    fi
  done
}

# region functions

log() { printf '[%s] [%s] %s\n' "$(date -u +%FT%TZ)" "$SCRIPT_NAME" "$*" >&2; }

alert_lifecycle() {
  local header="$1" line
  line=$(log "$2" 2>&1)
  printf '%s\n' "$line" >&2
  # The alert must have time to finish before Docker stops the container.
  timeout -k 1 5 "$POST_MESSAGE" "$MAX_ALERT_CHAT_ID" <<<"$header"$'\n'"[ms-logs] $line" >/dev/null ||
    log 'Could not send lifecycle alert'
}

# Message files are hidden until they are atomically renamed.
queue_message() {
  local channel="$1" body="$2" tmp dest part
  [[ -n "$body" ]] || return 0
  # Split before queuing: HTML entities may expand the text in post-message.sh.
  while IFS= read -r -d '' part; do
    tmp=$(mktemp "$WORK_DIR/queue/$channel/.message.XXXXXXXX")
    printf '%s' "$part" >"$tmp"
    ((QUEUE_SEQ += 1))
    printf -v dest '%s/queue/%s/%020d-%06d-%06d.txt' "$WORK_DIR" "$channel" "$(date +%s)" "$$" "$QUEUE_SEQ"
    mv -- "$tmp" "$dest"
  done < <(printf '%s' "$body" | jq -Rsrj --argjson limit "$((LOG_MAX_CHARS - 11))" '
    def width: if . == "&" then 5 elif . == "<" or . == ">" then 4 else 1 end;
    [explode[] | [.] | implode]
    | reduce .[] as $ch ([{text:"", n:0}];
        if .[-1].n + ($ch | width) > $limit then
          . + [{text:$ch, n:($ch | width)}]
        else
          .[-1].text += $ch | .[-1].n += ($ch | width)
        end)
    | .[].text + "\u0000"
  ')
}

# Split on actual characters, including the header, not on bytes.
queue_file() {
  local channel="$1" header="$2" file="$3" chunk="$2" line part
  while IFS= read -r line || [[ -n "$line" ]]; do
    while ((${#line} + ${#header} + 1 > LOG_MAX_CHARS)); do
      part="${line:0:LOG_MAX_CHARS-${#header}-1}"
      if [[ "$chunk" != "$header" ]]; then queue_message "$channel" "$chunk"; chunk="$header"; fi
      queue_message "$channel" "$header"$'\n'"$part"
      line="${line:${#part}}"
    done
    if ((${#chunk} + ${#line} + 1 > LOG_MAX_CHARS)); then
      queue_message "$channel" "$chunk"
      chunk="$header"
    fi
    chunk+=$'\n'"$line"
  done <"$file"
  [[ "$chunk" == "$header" ]] || queue_message "$channel" "$chunk"
}

flush_debug() {
  [[ -n "$DEBUG_TEXT" ]] && queue_message debug "$DEBUG_TEXT"
  DEBUG_TEXT=""
  DEBUG_STARTED=0
}

append_debug() {
  local line="$1"
  (( DEBUG_STARTED > 0 )) || DEBUG_STARTED="${EPOCHREALTIME/./}"
  if ((${#DEBUG_TEXT} + ${#line} + 1 > LOG_MAX_CHARS)); then
    flush_debug
    DEBUG_STARTED="${EPOCHREALTIME/./}"
  fi
  # An individual Docker line may exceed MAX's limit.
  while ((${#line} > LOG_MAX_CHARS)); do
    [[ -z "$DEBUG_TEXT" ]] || flush_debug
    queue_message debug "${line:0:LOG_MAX_CHARS}"
    line="${line:LOG_MAX_CHARS}"
    DEBUG_STARTED="${EPOCHREALTIME/./}"
  done
  if [[ -n "$DEBUG_TEXT" ]]; then DEBUG_TEXT+=$'\n'; fi
  DEBUG_TEXT+="$line"
}

flush_incident() {
  [[ -n "$INCIDENT_FILE" ]] || return 0
  local header="$( [[ "$INCIDENT_LEVEL" == ERROR ]] && printf '🚨 ERROR' || printf '⚠️ WARN' )"
  queue_file error "$header" "$INCIDENT_FILE"
  rm -f "$INCIDENT_FILE"
  INCIDENT_FILE=""
  INCIDENT_DEADLINE=0
  INCIDENT_LEVEL=""
}

handle_line() {
  local id="$1" line="$2" name formatted severity="" context header
  name="${NAMES[$id]:-$id}"
  formatted="[$name] $line"
  append_debug "$formatted"

  # Never alert on our own logs, but include them in DEBUG.
  if [[ "$id" != "$SELF_ID" ]]; then
    if [[ "$line" =~ \[(SUCCESS|ALERT)\] ]]; then
      case "${BASH_REMATCH[1]}" in
        SUCCESS) header='✅ SUCCESS' ;;
        ALERT) header='🔔 ALERT' ;;
      esac
      queue_message alert "$header"$'\n'"$formatted"
      return 0
    elif [[ "$line" =~ (^|[^[:alnum:]_])([Ee][Rr][Rr][Oo][Rr]|[Ee][Rr][Rr]|[Ff][Aa][Tt][Aa][Ll]|[Cc][Rr][Ii][Tt][Ii][Cc][Aa][Ll]|[Pp][Aa][Nn][Ii][Cc]|[Ee][Xx][Cc][Ee][Pp][Tt][Ii][Oo][Nn]|[Tt][Rr][Aa][Cc][Ee][Bb][Aa][Cc][Kk]|[Ff][Aa][Ii][Ll][Ee][Dd]|[Ff][Aa][Ii][Ll][Uu][Rr][Ee])([^[:alnum:]_]|$) ]]; then
      severity=ERROR
    elif [[ "$line" =~ (^|[^[:alnum:]_])([Ww][Aa][Rr][Nn]|[Ww][Aa][Rr][Nn][Ii][Nn][Gg]|[Dd][Ee][Pp][Rr][Ee][Cc][Aa][Tt][Ee][Dd])([^[:alnum:]_]|$) ]]; then
      severity=WARN
    fi

    if [[ -z "$INCIDENT_FILE" && -n "$severity" ]]; then
      INCIDENT_FILE=$(mktemp "$WORK_DIR/.incident.XXXXXXXX")
      for context in "${RING[@]}"; do printf '%s\n' "$context" >>"$INCIDENT_FILE"; done
      INCIDENT_DEADLINE=$(( ${EPOCHREALTIME/./} + INCIDENT_DELAY_SECONDS * 1000000 ))
      INCIDENT_LEVEL="$severity"
    elif [[ "$severity" == ERROR && -n "$INCIDENT_FILE" ]]; then
      INCIDENT_LEVEL=ERROR
    fi
  fi

  [[ -z "$INCIDENT_FILE" ]] || printf '%s\n' "$formatted" >>"$INCIDENT_FILE"
  RING+=("$formatted")
  if ((${#RING[@]} > CONTEXT_BEFORE_LINES)); then RING=("${RING[@]:1}"); fi
}

handle_record() {
  local record="$1" id line file
  id="${record%%$'\t'*}"
  [[ "$id" != "$record" ]] || return 0
  line="${record#*$'\t'}"
  if [[ "$id" == @* ]]; then
    id="${id#@}"
    file="$WORK_DIR/$line"
    IFS= read -r line <"$file"
    rm -f -- "$file"
  fi
  handle_line "$id" "$line"
}

watch_container() {
  local id="$1" started="$2" line file
  # Each FIFO write is <= PIPE_BUF even with UTF-8, preventing interleaved lines.
  docker logs --follow --since "$started" "$id" 2>&1 | while IFS= read -r line || [[ -n "$line" ]]; do
    if (( ${#line} > 900 )); then
      file=$(mktemp "$WORK_DIR/.line.XXXXXXXX")
      printf '%s\n' "$line" >"$file"
      printf '@%s\t%s\n' "$id" "${file##*/}" >&3
    else
      printf '%s\t%s\n' "$id" "$line" >&3
    fi
  done
}

watch_new_containers() {
  local id name since
  while IFS= read -r id; do
    [[ -n "$id" ]] || continue
    if [[ -n "${WATCHED[$id]:-}" ]] && kill -0 "${WATCHED[$id]}" 2>/dev/null; then continue; fi
    name=$(docker inspect --format '{{.Name}}' "$id" 2>/dev/null) || continue
    NAMES["$id"]="${name#/}"
    since="$STARTED_AT"
    if [[ -n "${WATCHED[$id]:-}" ]]; then since="$(date -u +%Y-%m-%dT%H:%M:%SZ)"; fi
    watch_container "$id" "$since" &
    WATCHED["$id"]="$!"
    CHILD_PIDS+=("$!")
  done < <(docker ps -q --filter "label=com.docker.compose.project=$PROJECT_NAME")
}

send_queue() {
  local channel="$1" chat_id="$2" file
  while :; do
    file=$(find "$WORK_DIR/queue/$channel" -maxdepth 1 -type f -name '*.txt' 2>/dev/null | sort | head -n 1) || true
    if [[ -z "$file" ]]; then
      sleep "$SEND_RETRY_SECONDS"
      continue
    fi
    if "$POST_MESSAGE" "$chat_id" <"$file" >/dev/null; then
      rm -f -- "$file"
    else
      log "Send to $channel failed; retrying"
      sleep "$SEND_RETRY_SECONDS"
    fi
  done
}

shutdown() {
  (( STOPPING == 0 )) || return
  STOPPING=1
  trap - TERM INT
  alert_lifecycle '🛑 STOP' "Stopped VERSION=$VERSION"
  local pid
  for pid in "${CHILD_PIDS[@]}"; do kill "$pid" 2>/dev/null || true; done
  wait 2>/dev/null || true
  exit 0
}

# endregion

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
