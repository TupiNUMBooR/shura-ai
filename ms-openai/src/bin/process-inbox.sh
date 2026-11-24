#!/usr/bin/env bash
# process-inbox.sh
set -euo pipefail

SCRIPT_NAME="${0##*/}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# optional environment
TRANSCRIBE="${TRANSCRIBE:-$SCRIPT_DIR/transcribe.sh}"
POST_FILE="${POST_FILE:-$SCRIPT_DIR/post-file.sh}"
CALCULATE_AUDIO_COST="${CALCULATE_AUDIO_COST:-$SCRIPT_DIR/calculate-audio-cost.sh}"
TRANSCRIBE_MODEL="${TRANSCRIBE_MODEL:-gpt-transcribe}"
SHOW_TRANSCRIPTION="${SHOW_TRANSCRIPTION:-false}"

main() {
  [[ $# -eq 1 ]] || error 2 "Usage: $SCRIPT_NAME UID_DIR"
  local uid_dir="$1" inbox="$1/inbox" ai="$1/ai" archive="$1/archive" outbox="$1/outbox"
  local operation="$1/operation.json" txt id file ext result text content image_id
  local stem response_file cost number next tmp op_tmp
  local messages=0 texts=0 images=0 audios=0 first_inbox="" last_inbox="" first_ai="" last_ai=""
  local -a attachments audio_records

  [[ -d "$inbox" ]] || error 66 "Inbox not found: $inbox"
  mkdir -p "$ai" "$archive"

  while true; do
    id="$(find "$inbox" -maxdepth 1 -type f -name '*.txt' -printf '%f\n' | LC_ALL=C sort -n | sed -n '1p')"
    if compgen -G "$inbox/[0-9]*.reset" >/dev/null; then return 0; fi
    [[ -n "$id" ]] || break
    txt="$inbox/$id"
    id="${id%.txt}"
    if (( messages == 0 )); then
      log "User ${uid_dir##*/} started"
      first_inbox="$id"
    fi

    # The AI has taken responsibility for this message.
    mkdir -p "$outbox"
    : >"$outbox/seen_$id"

    # The text file is the message marker. All other files with this ID are attachments.
    mapfile -d '' -t attachments < <(find "$inbox" -maxdepth 1 -type f -name "$id.*" ! -name "$id.txt" -print0 | sort -z)
    text="$(cat "$txt")"
    [[ ! "$text" =~ [^[:space:]] ]] || ((texts += 1))
    content='[]'
    audio_records=()

    for file in "${attachments[@]}"; do
      if compgen -G "$inbox/[0-9]*.reset" >/dev/null; then return 0; fi
      ext="${file##*.}"
      ext="${ext,,}"
      case "$ext" in
        ogg|m4a|mp3|mp4|mpeg|mpga|wav|webm|flac)
          ((audios += 1))
          result="$("$TRANSCRIBE" "$file")" || error 70 "Transcription failed: $file"
          jq -e '.text | type == "string"' <<<"$result" >/dev/null || error 65 "Invalid transcription: $file"
          stem="$(timestamp)"
          response_file="${stem}_transcriptions_response.json"
          write_json "$archive/$response_file" "$result"
          cost="$("$CALCULATE_AUDIO_COST" "$TRANSCRIBE_MODEL" <<<"$result")" || error 70 "Audio pricing failed: $file"
          [[ "$cost" =~ ^[0-9]+([.][0-9]+)?$ ]] || error 65 "Invalid cost: $cost"
          result="$(jq -r '.text' <<<"$result")"
          if [[ "$SHOW_TRANSCRIPTION" == true && -n "$result" ]]; then
            mkdir -p "$outbox"
            tmp=$(mktemp "$outbox/.transcription.XXXXXX")
            printf '🎙️ Я услышала:\n\n«%s»\n' "$result" >"$tmp"
            mv -f "$tmp" "$outbox/transcription_${id}_${audios}.txt"
          fi
          [[ -z "$result" ]] || text="${text:+$text$'\n'}$result"
          audio_records+=("$(jq -nc --arg response "$response_file" --argjson usd "$cost" '{response:$response,usd:$usd}')")
          ;;
        jpg|jpeg|png|webp|gif)
          ((images += 1))
          result="$("$POST_FILE" "$file")" || error 70 "Upload failed: $file"
          image_id="$(jq -er '.id // .file_id | select(type == "string" and length > 0)' <<<"$result")" || error 65 "No file ID: $file"
          content="$(jq -c --arg id "$image_id" '. + [{type:"input_image",file_id:$id}]' <<<"$content")"
          ;;
        *) error 65 "Unsupported attachment: $file" ;;
      esac
    done

    if [[ ! "$text" =~ [^[:space:]] && "$content" == '[]' ]]; then
      rm -f -- "$txt" "${attachments[@]}"
      continue
    fi

    # Preserve string content for text-only messages.
    if [[ "$content" == '[]' ]]; then
      result="$(jq -nc --arg text "$text" '{role:"user",content:$text}')"
    else
      content="$(jq -c --arg text "$text" 'if $text == "" then . else [{type:"input_text",text:$text}] + . end' <<<"$content")"
      result="$(jq -nc --argjson content "$content" '{role:"user",content:$content}')"
    fi

    number="$(find "$ai" -maxdepth 1 -type f -name '*_[ua].json' -printf '%f\n' | sed -nE 's/^([0-9]+)_[ua]\.json$/\1/p' | sort -n | tail -n 1)"
    next=$((10#${number:-0} + 1))
    printf -v number '%06d' "$next"
    [[ ! -e "$ai/${number}_u.json" ]] || error 73 "History collision: $number"
    write_json "$ai/${number}_u.json" "$result"

    # Record audio costs only after the user message has been committed.
    if [[ ! -f "$operation" ]]; then
      write_json "$operation" "$(jq -nc --arg started_at "$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)" '{started_at:$started_at,transcriptions:[]}')"
    fi
    for result in "${audio_records[@]}"; do
      op_tmp="$(mktemp "$uid_dir/.operation.XXXXXX")"
      if jq --argjson record "$result" '.transcriptions = ((.transcriptions // []) + [$record])' "$operation" >"$op_tmp"; then
        mv -f "$op_tmp" "$operation"
      else
        rm -f "$op_tmp"
        error 65 "Invalid operation.json"
      fi
    done

    rm -f -- "$txt" "${attachments[@]}"
    ((messages += 1))
    last_inbox="$id"
    [[ -n "$first_ai" ]] || first_ai="$number"
    last_ai="$number"
  done

  if ((messages > 0)); then
    local summary="${messages}m" inbox_range="$first_inbox" ai_range="$first_ai"
    ((texts == 0)) || summary+=" ${texts}t"
    ((images == 0)) || summary+=" ${images}i"
    ((audios == 0)) || summary+=" ${audios}a"
    [[ "$first_inbox" == "$last_inbox" ]] || inbox_range+="-$last_inbox"
    [[ "$first_ai" == "$last_ai" ]] || ai_range+="-$last_ai"
    log "User ${uid_dir##*/} completed: $summary, inbox/ $inbox_range, ai/ $ai_range"
  fi
}

timestamp() {
  local name
  while true; do
    name="$(date -u +%Y%m%d_%H%M%S_%3N)"
    [[ ! -e "$archive/${name}_transcriptions_response.json" ]] && { printf '%s\n' "$name"; return; }
    sleep 0.01
  done
}

write_json() {
  local target="$1" json="$2" tmp
  tmp="$(mktemp "$(dirname "$target")/.tmp.XXXXXX")"
  if jq -e . <<<"$json" >"$tmp"; then
    mv -f "$tmp" "$target"
  else
    rm -f "$tmp"
    error 65 "Invalid JSON for $target"
  fi
}

log()   { printf '[%s] [%s] %s\n' "$(date -u +%FT%TZ)" "$SCRIPT_NAME" "$*" >&2; }
error() { local code="$1"; shift; log "[ERROR] $*"; exit "$code"; }

main "$@"
