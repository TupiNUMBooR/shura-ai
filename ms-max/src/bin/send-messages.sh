#!/usr/bin/env bash
# send-messages.sh
set -euo pipefail

SCRIPT_NAME="$(basename "$0")"

# optional environment
DB_DIR="${DB_DIR:-./db}"
POST_MESSAGE="${POST_MESSAGE:-$(dirname "${BASH_SOURCE[0]}")/post-message.sh}"
MARK_SEEN="${MARK_SEEN:-$(dirname "${BASH_SOURCE[0]}")/mark-seen.sh}"
TYPING="${TYPING:-$(dirname "${BASH_SOURCE[0]}")/typing.sh}"

main() {
  [[ $# -eq 0 ]] || error 2 "Unexpected arguments"

  local LC_ALL=C
  local file uid_dir action rejected=0
  local -A queued=()

  # The glob yields paths in order. Keep the first ready file of each type.
  for file in "$DB_DIR"/users/*/outbox/*; do
    [[ -f "$file" && ! -L "$file" ]] || continue
    uid_dir="${file%/outbox/*}"
    [[ ! -L "$uid_dir" && ! -L "$uid_dir/outbox" ]] || continue
    case "${file##*/}" in
      .*) continue ;;
      seen|seen_*) action=seen ;;
      typing) action=typing ;;
      *.txt) action=message ;;
      message_*.json) action=json ;;
      *)
        move_failed "$file" "$uid_dir" 'Unknown outbox file type' 2>&1 |
          tee -a "$uid_dir/log.txt" >&2
        rejected=1
        continue
        ;;
    esac
    if [[ -z "${queued[$action]-}" ]]; then
      queued[$action]="$file"
    fi
  done

  for action in seen typing message json; do
    file="${queued[$action]-}"
    if [[ -f "$file" ]]; then
      dispatch "$file" "$action"
      return
    fi
  done

  (( rejected )) || sleep 0.25
}

dispatch() {
  local file="$1" action="$2" uid_dir uid chat_id

  uid_dir="${file%/outbox/*}"
  uid="${uid_dir##*/}"
  chat_id=""
  if [[ -f "$uid_dir/max_chat_id.txt" ]]; then
    chat_id=$(<"$uid_dir/max_chat_id.txt")
  fi
  [[ "$chat_id" =~ ^-?[0-9]+$ ]] || chat_id=""

  # Route every line from this user's action (including child errors) to both logs.
  process_action "$file" "$uid_dir" "$uid" "$chat_id" "$action" 2>&1 |
    tee -a "$uid_dir/log.txt" >&2
}

process_action() {
  local file="$1" uid_dir="$2" uid="$3" chat_id="$4" action="$5"
  local attempt chunk tmp sent

  if [[ "$action" == json ]]; then
    local payload
    if ! payload=$(jq -ces '
      select(length == 1) | .[0]
      | select(type == "object" and (.text | type == "string" and length > 0))
      | (if has("buttons") then .buttons else [] end) as $buttons
      | select($buttons | type == "array" and all(.[];
          type == "array" and length > 0 and all(.[];
            type == "object" and (.text | type == "string" and length > 0)
            and (
              (.type == "callback" and (.payload | type == "string"))
              or (.type == "link" and (.url | type == "string" and startswith("https://")))
            )
          )
        ))
      | {
          text,
          attachments: (if ($buttons | length) == 0 then []
                        else [{type: "inline_keyboard", payload: {buttons: $buttons}}]
                        end)
        }
    ' "$file"); then
      move_failed "$file" "$uid_dir" 'Invalid outbox message'
      return
    fi
    if [[ -n "$payload" && "$uid" =~ ^[0-9]+$ && -n "$chat_id" ]] &&
      printf '%s\n' "$payload" | "$POST_MESSAGE" --json "$chat_id" >/dev/null; then
      rm -f -- "$file"
      log "Sent to $uid"
    else
      move_failed "$file" "$uid_dir" "Failed to send to $uid"
    fi
    return 0
  fi

  if [[ "$action" != message ]]; then
    if [[ -s "$file" ]]; then
      move_failed "$file" "$uid_dir" "Expected an empty $action marker"
      return
    fi
    if [[ "$action" == typing ]]; then
      rm -f -- "$file"
      if [[ -n "$chat_id" ]]; then "$TYPING" "$chat_id" || :; fi
      return 0
    fi
    if [[ -n "$chat_id" ]]; then
      "$MARK_SEEN" "$chat_id" || :
    fi
    rm -f -- "$file"
    return 0
  fi

  if [[ "$uid" =~ ^[0-9]+$ && -n "$chat_id" ]]; then
    while [[ -s "$file" ]]; do
      chunk=$(jq -Rs -c '
        if length <= 3500 then {part: ., rest: ""}
        else
          .[0:3500] as $head |
          ($head | rindex("\n")) as $nl |
          ($head | rindex(" ")) as $sp |
          (if $nl != null and $nl > 1750 then $nl + 1
           elif $sp != null and $sp > 1750 then $sp + 1
           else 3500 end) as $n |
          {part: .[0:$n], rest: .[$n:]}
        end
      ' < "$file") || error 70 "Cannot split $file"

      sent=0
      for attempt in 1 2 3; do
        if jq -j '.part' <<< "$chunk" |
           "$POST_MESSAGE" "$chat_id" > /dev/null; then
          sent=1
          tmp=$(mktemp "$uid_dir/outbox/.part.XXXXXX")
          jq -j '.rest' <<< "$chunk" > "$tmp"
          mv -- "$tmp" "$file" || error 73 "Cannot update $file"
          log "Sent to $uid"
          break
        fi
        if (( attempt < 3 )); then sleep 1; fi
      done

      if (( ! sent )); then
        move_failed "$file" "$uid_dir" "Failed to send to $uid"
        return 0
      fi
    done

    rm -- "$file" || error 73 "Cannot remove $file"
    return 0
  fi

  move_failed "$file" "$uid_dir" "Invalid recipient for $uid"
}

move_failed() {
  local file="$1" uid_dir="$2" reason="$3"
  mkdir -p "$uid_dir/outbox-failed"
  mv -- "$file" "$uid_dir/outbox-failed/" \
    || error 73 "Cannot move failed message: $file"
  log "[WARN] $reason: $file (moved to outbox-failed)"
}

# region functions

log()   { printf '[%s] [%s] %s\n' "$(date -u +%FT%TZ)" "$SCRIPT_NAME" "$*" >&2; }
error() { local code="$1"; shift; log "[ERROR] $*"; exit "$code"; }

# endregion

main "$@"
