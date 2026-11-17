#!/usr/bin/env bash
# process-inbox.sh
set -euo pipefail

SCRIPT_NAME="$(basename "$0")"

# optional environment
DB_DIR="${DB_DIR:-./db}"
VERBOSE="${VERBOSE:-0}"
POLL_MAX="${POLL_MAX:-$(dirname "$0")/poll.sh}"

MARKER_FILE="$DB_DIR/marker.txt"
tmp=""

main() {
  [[ $# -eq 0 ]] || { echo "Unexpected arguments" >&2; return 2; }

  mkdir -p "$DB_DIR/users"
  trap '[[ -z "$tmp" ]] || rm -f "$tmp"' EXIT

  local marker="" response new_marker updates update
  local user seq chat_id uid_dir inbox attachment type url ext mime n filename message_count

  [[ ! -f "$MARKER_FILE" ]] || marker=$(<"$MARKER_FILE")
  response=$("$POLL_MAX" ${marker:+"$marker"})
  new_marker=$(jq -r '.marker // empty' <<<"$response")
  local counts
  counts=$(jq -r '
    [.updates[] | select(.update_type == "message_created")] as $messages |
    "\($messages | length)m " +
    "\($messages | map(select((.message.body.text // "") | length > 0)) | length)t " +
    "\($messages | [.[].message.body.attachments[]? | select(.type == "image")] | length)i " +
    "\($messages | [.[].message.body.attachments[]? | select(.type == "audio")] | length)a"
  ' <<<"$response")
  if [[ "$counts" != 0m* ]]; then
    printf '[%s] [%s] Received: %s\n' \
      "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$SCRIPT_NAME" "$counts" >&2
  fi

  updates=$(jq -c '
    [.updates[]
      | select(.update_type == "message_created")
      | select(.message.sender.user_id != null)
      | select(.message.body.seq != null)]
    | sort_by(.message.body.seq)
    | .[]
  ' <<<"$response")

  while IFS= read -r update; do
    [[ -n "$update" ]] || continue

    user=$(jq -r '.message.sender.user_id' <<<"$update")
    seq=$(jq -r '.message.body.seq' <<<"$update")
    [[ "$user" =~ ^[0-9]+$ && "$seq" =~ ^[0-9]+$ ]] || return 65

    uid_dir="$DB_DIR/users/$user"
    inbox="$uid_dir/inbox"
    mkdir -p "$inbox"
    chat_id=$(jq -r '.message.recipient.chat_id // empty' <<<"$update")
    if [[ "$chat_id" =~ ^-?[0-9]+$ ]]; then
      tmp=$(mktemp "$uid_dir/.chat.XXXXXX")
      printf '%s\n' "$chat_id" >"$tmp"
      mv -f -- "$tmp" "$uid_dir/max_chat_id.txt"
      tmp=""
    fi
    [[ ! -f "$inbox/$seq.txt" ]] || continue

    n=0
    while IFS= read -r attachment; do
      ((n+=1))
      type=$(jq -r '.type' <<<"$attachment")

      case "$type" in
        image|audio) ;;
        *) continue ;;
      esac

      printf -v filename '%s.%02d' "$seq" "$n"

      # Already downloaded.
      if compgen -G "$inbox/$filename.*" >/dev/null; then
        continue
      fi

      url=$(jq -r '.payload.url // empty' <<<"$attachment")
      [[ -n "$url" ]] || { echo "Missing attachment URL" >&2; return 65; }

      tmp=$(mktemp)
      mime=$(curl -fsSL -w '%{content_type}' -o "$tmp" "$url")

      case "$mime" in
        image/jpeg*)       ext=jpg ;;
        image/png*)        ext=png ;;
        image/gif*)        ext=gif ;;
        image/webp*)       ext=webp ;;
        image/heic*)       ext=heic ;;
        audio/mpeg*)       ext=mp3 ;;
        audio/ogg*|application/ogg*) ext=ogg ;;
        audio/mp4*|audio/x-m4a*) ext=m4a ;;
        audio/aac*)        ext=aac ;;
        audio/wav*|audio/x-wav*) ext=wav ;;
        *)                 echo "Unsupported media type: $mime" >&2; return 65 ;;
      esac

      mv "$tmp" "$inbox/$filename.$ext"
      tmp=""
    done < <(jq -c '.message.body.attachments[]?' <<<"$update")

    # Publish the message only after all attachments.
    tmp=$(mktemp "$inbox/.message.XXXXXX")
    jq -j '.message.body.text // ""' <<<"$update" >"$tmp"
    mv "$tmp" "$inbox/$seq.txt"
    tmp=""

    if [[ "$VERBOSE" == "1" ]]; then echo "Saved user=$user seq=$seq" >&2; fi
  done <<<"$updates"

  if [[ -n "$new_marker" ]]; then
    tmp=$(mktemp)
    printf '%s\n' "$new_marker" >"$tmp"
    mv "$tmp" "$MARKER_FILE"
    tmp=""
  fi
}

main "$@"
