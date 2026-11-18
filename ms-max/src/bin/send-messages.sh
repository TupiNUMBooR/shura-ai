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

  local file uid uid_dir chat_id action

  [[ -d "$DB_DIR/users" ]] || return 0

  # Control events first; ordinary messages only when no actions are pending.
  file=$(find "$DB_DIR/users" -ignore_readdir_race -type f \
    \( -path '*/outbox/seen' -o -path '*/outbox/seen_*' \) | LC_ALL=C sort | head -n 1)
  if [[ -n "$file" ]]; then
    action=seen
  else
    file=$(find "$DB_DIR/users" -ignore_readdir_race -type f -path '*/outbox/typing' | LC_ALL=C sort | head -n 1)
    if [[ -n "$file" ]]; then
      action=typing
    else
      file=$(find "$DB_DIR/users" -ignore_readdir_race -type f -path '*/outbox/*.txt' | LC_ALL=C sort | head -n 1)
      action=message
      if [[ -z "$file" ]]; then
        file=$(find "$DB_DIR/users" -ignore_readdir_race -type f -path '*/outbox/*.json' | LC_ALL=C sort | head -n 1)
        action=json
      fi
    fi
  fi
  [[ -n "$file" && -f "$file" ]] || return 0

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
    if [[ "${file##*/}" == payment_* ]]; then
      payload=$(jq -ce '
        . as $p | ($p.yookassa.confirmation.confirmation_url // $p.confirmation_url) as $url |
        select(($url | type) == "string" and ($url | startswith("https://"))) |
        {text:("Оплата " + ($p.credits|tostring) + " кредитов за " + ($p.rub|tostring) + " ₽"),
         attachments:[{type:"inline_keyboard",payload:{buttons:[[ {type:"link",text:"Оплатить",url:$url} ]]}}]}
      ' "$file") || error 65 "Invalid payment: $file"
    else
      payload="$(cat "$file")"
    fi
    if [[ "$uid" =~ ^[0-9]+$ && -n "$chat_id" ]] && printf '%s\n' "$payload" | "$POST_MESSAGE" --json "$chat_id" >/dev/null; then
      rm -f -- "$file"
      log "Sent to $uid"
    else
      mkdir -p "$uid_dir/outbox-failed"
      mv -- "$file" "$uid_dir/outbox-failed/"
      log "[WARN] Failed to send to $uid (moved to outbox-failed)"
    fi
    return 0
  fi

  if [[ "$action" != message ]]; then
    if [[ -n "$chat_id" ]]; then
      if [[ "$action" == seen ]]; then
        "$MARK_SEEN" "$chat_id" || :
      else
        "$TYPING" "$chat_id" || :
      fi
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
          tmp=$(mktemp "$file.XXXXXX")
          jq -j '.rest' <<< "$chunk" > "$tmp"
          mv -- "$tmp" "$file" || error 73 "Cannot update $file"
          log "Sent to $uid"
          break
        fi
        if (( attempt < 3 )); then sleep 1; fi
      done

      if (( ! sent )); then
        mkdir -p "$uid_dir/outbox-failed"
        mv -- "$file" "$uid_dir/outbox-failed/" \
          || error 73 "Cannot move failed message: $file"
        log "[WARN] Failed to send to $uid (moved to outbox-failed)"
        return 0
      fi
    done

    rm -- "$file" || error 73 "Cannot remove $file"
    return 0
  fi

  mkdir -p "$uid_dir/outbox-failed"
  mv -- "$file" "$uid_dir/outbox-failed/" \
    || error 73 "Cannot move failed message: $file"

  log "[WARN] Failed to send to $uid (moved to outbox-failed)"
}

# region functions

log()   { printf '[%s] [%s] %s\n' "$(date -u +%FT%TZ)" "$SCRIPT_NAME" "$*" >&2; }
error() { local code="$1"; shift; log "[ERROR] $*"; exit "$code"; }

# endregion

main "$@"
