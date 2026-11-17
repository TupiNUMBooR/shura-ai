#!/usr/bin/env bash
# process-user.sh — полный цикл ответа одному пользователю.
#
# Usage: process-user.sh UID_DIR
# UID_DIR = /db/<service>/users/<id>; обрабатывается один пользователь за запуск.
#
# Алгоритм:
#   1. Создаёт user.json из user.default.json, если пользователя ещё нет.
#   2. Если история заканчивается на *_u.json, сразу продолжает ответ:
#      уже подготовленное сообщение обрабатывается независимо от баланса.
#   3. Иначе, если inbox пуст — выходит (само пополнение не будит delayed).
#      Если кредитов нет — переносит всю пачку inbox/* в inbox-delayed/
#      и отправляет ОДНО уведомление в outbox; исходники не удаляет.
#      Если кредиты есть — возвращает delayed/* в inbox/ и вызывает
#      process-inbox.sh (текст/аудио/картинки → ai/*_u.json).
#   4. Собирает запрос из agent.json, user.system_message и хвоста ai/*.json
#      в пределах приблизительного CONTEXT_TOKENS; архивирует request.
#   5. Вызывает Responses API ОДИН раз, проверяет и архивирует response.
#      Стоимость ответа добавляет в operation.json к стоимости транскрипций.
#   6. Записывает текст в outbox, output модели (включая reasoning) в *_a.json.
#   7. Суммирует USD, округляет кредиты вверх (CREDITS_PER_USD), списывает
#      в user.json и переносит operation.json в архив. При исчерпании
#      кредитов после ответа добавляет уведомление в outbox.
#
# Файлы пользователя: inbox/, inbox-delayed/, ai/, outbox/, archive/,
# user.json и временный operation.json. Архивы: *_responses_request.json,
# *_responses_response.json, *_operation.json; транскрипции архивирует
# process-inbox.sh. Внешние кирпичи задаются переменными окружения.
#
# Упрощение по дизайну: это НЕ транзакция. При падении между записью ответа,
# истории и списанием возможны повторный ответ или потеря начисления.
# Доставку из outbox выполняет другой сервис; тут она не подтверждается.
set -euo pipefail

SCRIPT_NAME="${0##*/}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# optional environment
PROCESS_INBOX="${PROCESS_INBOX:-$SCRIPT_DIR/process-inbox.sh}"
POST_RESPONSES="${POST_RESPONSES:-$SCRIPT_DIR/post-responses.sh}"
CALCULATE_TEXT_COST="${CALCULATE_TEXT_COST:-$SCRIPT_DIR/calculate-text-cost.sh}"
AGENT_FILE="${AGENT_FILE:-$SCRIPT_DIR/../config/agent.json}"
USER_DEFAULT_FILE="${USER_DEFAULT_FILE:-$SCRIPT_DIR/../config/user.default.json}"
CREDITS_PER_USD="${CREDITS_PER_USD:-100000}"
CONTEXT_TOKENS="${CONTEXT_TOKENS:-128000}"
NO_CREDITS_MESSAGE="${NO_CREDITS_MESSAGE:-Кредиты закончились. Пополни баланс, чтобы продолжить.}"

main() {
  [[ $# -eq 1 ]] || error 2 "Usage: $SCRIPT_NAME UID_DIR"
  local uid_dir="$1" user="$1/user.json" ai="$1/ai" archive="$1/archive"
  local operation="$1/operation.json" outbox="$1/outbox" delayed="$1/inbox-delayed" balance
  local last last_type number stamp request response cost text credits total_usd tmp

  [[ -d "$uid_dir/inbox" ]] || error 66 "Inbox not found: $uid_dir/inbox"
  [[ -f "$AGENT_FILE" ]] || error 66 "Agent not found: $AGENT_FILE"
  [[ "$CREDITS_PER_USD" =~ ^[0-9]+$ ]] && (( CREDITS_PER_USD > 0 )) || error 65 "Invalid CREDITS_PER_USD"
  [[ "$CONTEXT_TOKENS" =~ ^[0-9]+$ ]] && (( CONTEXT_TOKENS > 0 )) || error 65 "Invalid CONTEXT_TOKENS"
  mkdir -p "$ai" "$archive" "$outbox"

  if [[ ! -f "$user" ]]; then
    [[ -f "$USER_DEFAULT_FILE" ]] || error 66 "User defaults not found: $USER_DEFAULT_FILE"
    write_json "$user" "$(cat "$USER_DEFAULT_FILE")"
  fi
  balance="$(jq -er '(.credits.received - .credits.spent) | select(type == "number")' "$user")" || error 65 "Invalid user credits"

  # A pending user history message must receive an answer regardless of balance.
  last="$(last_history "$ai")"
  if [[ "$last" != *_u.json ]]; then
    # No new message means no processing, even if delayed messages exist.
    local -a incoming=() delayed_files=()
    shopt -s nullglob
    incoming=("$uid_dir/inbox/"*)
    shopt -u nullglob
    (( ${#incoming[@]} > 0 )) || return 0

    if jq -ne --argjson balance "$balance" '$balance <= 0' >/dev/null; then
      mkdir -p "$delayed"
      mv -n -- "${incoming[@]}" "$delayed/"
      write_outbox "$outbox" "$NO_CREDITS_MESSAGE"
      log 'No credits: deferred inbox and sent notification'
      return 0
    fi

    if [[ -d "$delayed" ]]; then
      shopt -s nullglob
      delayed_files=("$delayed/"*)
      shopt -u nullglob
      if (( ${#delayed_files[@]} > 0 )); then
        mv -n -- "${delayed_files[@]}" "$uid_dir/inbox/"
      fi
    fi
    "$PROCESS_INBOX" "$uid_dir"
  fi
  last="$(last_history "$ai")"
  [[ "$last" == *_u.json ]] || return 0
  number="${last##*/}"; number="${number%_u.json}"

  stamp="$(timestamp "$archive")"
  request="$archive/${stamp}_responses_request.json"
  response="$archive/${stamp}_responses_response.json"

  # Select a contiguous suffix of history. Conservative character-based
  # approximation: exact token counts are returned by OpenAI only afterward.
  tmp="$(mktemp "$uid_dir/.request.XXXXXX")"
  if ! build_request "$user" "$ai" >"$tmp"; then rm -f "$tmp"; error 65 'Cannot build request'; fi
  mv -f "$tmp" "$request"

  log "AI ${number} started"

  # Tell the messenger the AI is generating a response.
  : >"$outbox/typing"

  # post-responses.sh receives the request JSON on stdin and returns response JSON on stdout.
  tmp="$(mktemp "$archive/.response.XXXXXX")"
  if ! "$POST_RESPONSES" <"$request" >"$tmp"; then
    rm -f "$tmp"
    error 70 'OpenAI request failed'
  fi
  jq -e '.status == "completed" and (.output | type == "array") and (.output | length > 0)' "$tmp" >/dev/null || {
    rm -f "$tmp"; error 65 'Incomplete or invalid OpenAI response';
  }
  mv -f "$tmp" "$response"
  cost="$("$CALCULATE_TEXT_COST" <"$response")" || error 70 'Cannot calculate response cost'
  [[ "$cost" =~ ^[0-9]+([.][0-9]+)?$ ]] || error 65 "Invalid cost: $cost"

  if [[ ! -f "$operation" ]]; then
    write_json "$operation" "$(jq -nc --arg started_at "$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)" '{started_at:$started_at,transcriptions:[]}')"
  fi
  update_json "$operation" --arg req "${request##*/}" --arg resp "${response##*/}" --argjson usd "$cost" \
    '.responses = {request:$req,response:$resp,usd:$usd}'

  text="$(jq -r '[.output[] | select(.type == "message") | .content[]? | select(.type == "output_text") | .text] | join("\n")' "$response")"
  [[ -n "$text" ]] || error 65 'Response has no output text'
  write_outbox "$outbox" "$text"
  # Save all output items (including reasoning) for subsequent context.
  write_json "$ai/${number}_a.json" "$(jq -c 'if (.output | length) == 1 then .output[0] else .output end' "$response")"

  total_usd="$(jq -er '[.transcriptions[]?.usd, .responses.usd] | add // 0' "$operation")"
  credits="$(jq -nr --argjson usd "$total_usd" --argjson multiplier "$CREDITS_PER_USD" '($usd * $multiplier | ceil)')"
  update_json "$user" --argjson usd "$total_usd" --argjson credits "$credits" \
    '.usd.spent += $usd | .credits.spent += $credits'
  update_json "$operation" --argjson credits "$credits" '.credits = $credits'
  mv -f "$operation" "$archive/${stamp}_operation.json"

  balance="$(jq -r '.credits.received - .credits.spent' "$user")"
  if jq -ne --argjson balance "$balance" '$balance <= 0' >/dev/null; then
    write_outbox "$outbox" "$NO_CREDITS_MESSAGE"
  fi
  log "AI ${number} completed: ${credits} credits, \$${total_usd}"
}

build_request() {
  local user="$1" ai="$2"
  local f data size limit files=() selected=()
  mapfile -t files < <(find "$ai" -maxdepth 1 -type f \( -name '*_u.json' -o -name '*_a.json' \) -printf '%f\n' | LC_ALL=C sort -t_ -k1,1n -k2,2r)
  # Use a conservative limit on JSON UTF-8 bytes (2 bytes per estimated token).
  limit=$((CONTEXT_TOKENS * 2))
  size=0
  for ((i=${#files[@]}-1; i>=0; i--)); do
    f="$ai/${files[i]}"
    data="$(wc -c <"$f")"
    (( size + data <= limit )) || { (( ${#selected[@]} > 0 )) && break; }
    selected=("$f" "${selected[@]}")
    size=$((size + data))
  done
  ((${#selected[@]} > 0)) || return 1
  jq -n --slurpfile agent "$AGENT_FILE" --slurpfile user "$user" \
    --slurpfile messages <(jq -s '[.[] | if type == "array" then .[] else . end]' "${selected[@]}") '
    $agent[0] + {
      instructions: ($agent[0].instructions + (if ($user[0].system_message // "") == "" then "" else "\n\n" + $user[0].system_message end)),
      input: $messages[0]
    }'
}

last_history() {
  find "$1" -maxdepth 1 -type f \( -name '*_u.json' -o -name '*_a.json' \) -printf '%f\n' | LC_ALL=C sort -t_ -k1,1n -k2,2r | tail -n 1
}

timestamp() {
  local name
  while true; do
    name="$(date -u +%Y%m%d_%H%M%S_%3N)"
    [[ ! -e "$1/${name}_responses_request.json" && ! -e "$1/${name}_operation.json" ]] && { printf '%s\n' "$name"; return; }
    sleep 0.01
  done
}

write_outbox() {
  local dir="$1" value="$2" tmp dest base suffix
  tmp="$(mktemp "$dir/.out.XXXXXX")"
  printf '%s\n' "$value" >"$tmp"
  base="$(date -u +%s)"
  dest="$dir/${base}.txt"
  suffix=0
  while [[ -e "$dest" ]]; do
    ((suffix += 1))
    dest="$dir/${base}-${suffix}.txt"
  done
  mv -n "$tmp" "$dest" || error 73 'Cannot create outbox message'
}

write_json() {
  local target="$1" json="$2" tmp
  tmp="$(mktemp "$(dirname "$target")/.tmp.XXXXXX")"
  if jq -e . <<<"$json" >"$tmp"; then mv -f "$tmp" "$target"; else rm -f "$tmp"; error 65 "Invalid JSON: $target"; fi
}

update_json() {
  local target="$1" tmp
  shift
  tmp="$(mktemp "$(dirname "$target")/.tmp.XXXXXX")"
  if jq "$@" "$target" >"$tmp"; then mv -f "$tmp" "$target"; else rm -f "$tmp"; error 65 "Cannot update: $target"; fi
}

log()   { printf '[%s] [%s] %s\n' "$(date -u +%FT%TZ)" "$SCRIPT_NAME" "$*" >&2; }
error() { local code="$1"; shift; log "[ERROR] $*"; exit "$code"; }

main "$@"
