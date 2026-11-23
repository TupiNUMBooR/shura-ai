#!/usr/bin/env bash
# receive-messages.sh
set -euo pipefail

SCRIPT_NAME="$(basename "$0")"

# optional environment
DB_DIR="${DB_DIR:-./db}"
VERBOSE="${VERBOSE:-0}"
POLL_MAX="${POLL_MAX:-$(dirname "$0")/poll.sh}"
PRICES_FILE="$(dirname "$0")/../config/credit-packages.json"
DEFAULT_CREDITS="$(dirname "$0")/../config/user.default/credits_received.txt"

MARKER_FILE="$DB_DIR/marker.txt"
tmp=""

main() {
  [[ $# -eq 0 ]] || { echo "Unexpected arguments" >&2; return 2; }

  mkdir -p "$DB_DIR/users"
  trap '[[ -z "$tmp" ]] || rm -f "$tmp"' EXIT

  local marker="" response new_marker updates update
  local user seq chat_id uid_dir inbox attachment type url ext mime n filename message_count command balance payload credits rub callback_id

  [[ ! -f "$MARKER_FILE" ]] || marker=$(<"$MARKER_FILE")
  response=$("$POLL_MAX" ${marker:+"$marker"})
  new_marker=$(jq -r '.marker // empty' <<<"$response")
  local counts
  counts=$(jq -r '
    [.updates[]
      | select(.update_type == "message_created")
      | select(.message.recipient.chat_type == "dialog")
    ] as $messages |
    ($messages | length) as $m |
    ($messages | map(select((.message.body.text // "") | startswith("/"))) | length) as $c |
    ($messages | map(select((((.message.body.text // "") | length) > 0) and (((.message.body.text // "") | startswith("/")) | not))) | length) as $t |
    ($messages | [.[].message.body.attachments[]? | select(.type == "image")] | length) as $i |
    ($messages | [.[].message.body.attachments[]? | select(.type == "audio")] | length) as $a |
    ["\($m)m", (if $c > 0 then "\($c)c" else empty end), (if $t > 0 then "\($t)t" else empty end),
     (if $i > 0 then "\($i)i" else empty end),
     (if $a > 0 then "\($a)a" else empty end)] | join(" ")
  ' <<<"$response")
  if [[ "$counts" != 0m* ]]; then
    printf '[%s] [%s] Received: %s\n' \
      "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$SCRIPT_NAME" "$counts" >&2
  fi

  updates=$(jq -c '
    [.updates[]
      | select(.update_type == "message_created")
      | select(.message.recipient.chat_type == "dialog")
      | select(.message.sender.user_id != null)
      | select(.message.body.seq != null)]
    | sort_by(.message.body.seq)
    | .[]
  ' <<<"$response")

  # Purchase callbacks are separate MAX update events, not user messages.
  while IFS= read -r update; do
    [[ -n "$update" ]] || continue
    user="$(jq -r '.callback.user.user_id // empty' <<<"$update")"
    payload="$(jq -r '.callback.payload // empty' <<<"$update")"
    callback_id="$(jq -r '.callback.callback_id // empty' <<<"$update")"
    [[ "$user" =~ ^[0-9]+$ ]] || continue
    [[ "$payload" =~ ^buy:([0-9]+)$ ]] || continue
    credits="${BASH_REMATCH[1]}"
    rub="$(jq -er --argjson credits "$credits" '.packages[] | select(.credits == $credits) | .rub' "$PRICES_FILE")" || continue
    uid_dir="$DB_DIR/users/$user"
    mkdir -p "$uid_dir"
    init_user "$uid_dir"
    mkdir -p "$uid_dir/payments/orders"
    tmp="$(mktemp "$uid_dir/payments/orders/.order.XXXXXX")"
    jq -nc --argjson credits "$credits" '{credits:$credits}' >"$tmp"
    # A duplicate click while an order exists must not overwrite it.
    ln "$tmp" "$uid_dir/payments/orders/$credits.json" 2>/dev/null || :
    rm -f "$tmp"; tmp=""
    if [[ -n "$callback_id" && -n "${MAX_BOT_TOKEN:-}" ]]; then
      tmp=$(mktemp "$uid_dir/.callback.XXXXXX")
      local http_code
      if http_code=$(curl --silent --show-error --connect-timeout 5 --max-time 15 \
          --output "$tmp" --write-out '%{http_code}' \
          -X POST -H "Authorization: $MAX_BOT_TOKEN" -H 'Content-Type: application/json' \
          -d '{"notification":"Создаю ссылку на оплату..."}' \
          "${MAX_API_URL:-https://platform-api2.max.ru}/answers?callback_id=$callback_id"); then
        if [[ "$http_code" != 200 && "$http_code" != 204 ]]; then
          echo "MAX callback HTTP $http_code: $(cat "$tmp")" >&2
        fi
      else
        echo 'MAX callback request failed' >&2
      fi
      rm -f "$tmp"; tmp=""
    fi
  done < <(jq -c '.updates[] | select(.update_type == "message_callback")' <<<"$response")

  while IFS= read -r update; do
    [[ -n "$update" ]] || continue

    user=$(jq -r '.message.sender.user_id' <<<"$update")
    seq=$(jq -r '.message.body.seq' <<<"$update")
    [[ "$user" =~ ^[0-9]+$ && "$seq" =~ ^[0-9]+$ ]] || return 65

    uid_dir="$DB_DIR/users/$user"
    inbox="$uid_dir/inbox"
    mkdir -p "$inbox"
    init_user "$uid_dir"
    chat_id=$(jq -r '.message.recipient.chat_id // empty' <<<"$update")
    if [[ "$chat_id" =~ ^-?[0-9]+$ ]]; then
      tmp=$(mktemp "$uid_dir/.chat.XXXXXX")
      printf '%s\n' "$chat_id" >"$tmp"
      mv -f -- "$tmp" "$uid_dir/max_chat_id.txt"
      tmp=""
    fi
    [[ ! -f "$inbox/$seq.txt" ]] || continue

    command=$(jq -r '.message.body.text // ""' <<<"$update")
    case "$command" in
      /start|/help)
        mkdir -p "$uid_dir/outbox"
        [[ ! -e "$uid_dir/outbox/$seq.txt" ]] || continue
        balance=$(balance_of "$uid_dir") || { echo "Invalid user credits: $user" >&2; return 65; }
        tmp=$(mktemp "$uid_dir/outbox/.help.XXXXXX")
        printf 'Привет! Я Шура 💜\n\nТвоя ИИ-помощница. Могу отвечать на вопросы, разбирать задачи и помогать с идеями.\n\nБаланс: %s кредитов\n\n/start или /help — справка\n/buy — купить кредиты\n/credits — мой баланс\n/reset — очистить историю\n' "$balance" >"$tmp"
        mv -- "$tmp" "$uid_dir/outbox/$seq.txt"
        tmp=""
        continue
        ;;
      /credits)
        mkdir -p "$uid_dir/outbox"
        balance=$(balance_of "$uid_dir") || { echo "Invalid user credits: $user" >&2; return 65; }
        tmp=$(mktemp "$uid_dir/outbox/.credits.XXXXXX")
        printf '💜 Твой баланс: %s кредитов\n' "$balance" >"$tmp"
        mv -- "$tmp" "$uid_dir/outbox/$seq.txt"
        tmp=""
        continue
        ;;
      /buy)
        mkdir -p "$uid_dir/outbox"
        balance=$(balance_of "$uid_dir") || { echo "Invalid user credits: $user" >&2; return 65; }
        tmp="$(mktemp "$uid_dir/outbox/.buy.XXXXXX")"
        jq -n --arg balance "$balance" --slurpfile prices "$PRICES_FILE" '
          {
            text: ("Пополнить баланс 💜\n\nТвой баланс: " + $balance + " кредитов\n\nВыбери пакет кредитов:"),
            buttons: [$prices[0].packages[] | [{
              type: "callback",
              text: "\(.credits) кредитов · \(.rub) ₽",
              payload: "buy:\(.credits)"
            }]]
          }
        ' >"$tmp"
        mv -- "$tmp" "$uid_dir/outbox/message_buy_${seq}.json"
        tmp=""
        continue
        ;;
      /*)
        mkdir -p "$uid_dir/outbox"
        tmp="$(mktemp "$uid_dir/outbox/.unknown.XXXXXX")"
        printf 'Нет такой команды. Используй /help.\n' >"$tmp"
        mv -- "$tmp" "$uid_dir/outbox/$seq.txt"
        tmp=""
        continue
        ;;
    esac

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

init_user() {
  local dir="$1" tmp
  [[ -f "$dir/credits_received.txt" ]] && return 0
  [[ -f "$DEFAULT_CREDITS" ]] || { echo "Missing default credits: $DEFAULT_CREDITS" >&2; return 66; }
  tmp=$(mktemp "$dir/.credits.XXXXXX") || return 73
  cat "$DEFAULT_CREDITS" >"$tmp"
  ln "$tmp" "$dir/credits_received.txt" 2>/dev/null || [[ -f "$dir/credits_received.txt" ]] || { rm -f "$tmp"; return 73; }
  rm -f "$tmp"
}

balance_of() {
  local dir="$1" received=0 spent=0
  [[ ! -f "$dir/credits_received.txt" ]] || received=$(<"$dir/credits_received.txt")
  [[ ! -f "$dir/credits_spent.txt" ]] || spent=$(<"$dir/credits_spent.txt")
  jq -nr --arg a "$received" --arg b "$spent" '($a | tonumber) - ($b | tonumber)'
}

main "$@"
