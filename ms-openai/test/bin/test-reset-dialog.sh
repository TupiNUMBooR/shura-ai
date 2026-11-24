#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROCESS_USER="$SCRIPT_DIR/../../src/bin/process-user.sh"
test_dir="$(mktemp -d)"
trap 'rm -rf -- "$test_dir"' EXIT

new_user() {
  export uid_dir="$test_dir/$1"
  mkdir -p "$uid_dir"/{inbox,inbox-delayed,ai,archive,outbox}
  printf '%s\n' "$2" >"$uid_dir/credits_received.txt"
}

new_user no_credits 0
touch "$uid_dir"/inbox/{9.txt,9.01.ogg,10.reset,11.txt}
touch "$uid_dir"/inbox-delayed/{8.txt,8.01.webp}
touch "$uid_dir"/{ai/000001_u.json,archive/prior.json,operation.json,outbox/previous.txt}
bash "$PROCESS_USER" "$uid_dir"
[[ -f "$uid_dir/inbox/11.txt" && -f "$uid_dir/archive/prior.json" && -f "$uid_dir/outbox/previous.txt" ]]
[[ ! -e "$uid_dir/operation.json" && ! -e "$uid_dir/credits_spent.txt" ]]
if compgen -G "$uid_dir/ai/*"; then exit 1; fi
if compgen -G "$uid_dir/inbox-delayed/*"; then exit 1; fi
if compgen -G "$uid_dir/inbox/9.*"; then exit 1; fi
[[ ! -e "$uid_dir/inbox/10.reset" ]]
grep -Fxq 'Начали новый диалог 💜' "$uid_dir"/outbox/*.txt
if grep -Fq 'Кредиты закончились' "$uid_dir"/outbox/*.txt; then exit 1; fi

cat >"$test_dir/transcribe" <<'MOCK'
#!/usr/bin/env bash
touch "$uid_dir/inbox/10.reset"
printf '%s\n' '{"text":"voice"}'
MOCK
cat >"$test_dir/cost" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' '0.000001'
MOCK
cat >"$test_dir/responses" <<'MOCK'
#!/usr/bin/env bash
cat >/dev/null
touch "$uid_dir/inbox/10.reset" "$uid_dir/request-sent"
printf '%s\n' '{"status":"completed","output":[{"type":"message","content":[{"type":"output_text","text":"Готовый ответ"}]}]}'
MOCK
chmod +x "$test_dir"/{transcribe,cost,responses}

new_user transcribing 10
touch "$uid_dir"/inbox/{9.txt,9.01.ogg}
TRANSCRIBE="$test_dir/transcribe" CALCULATE_AUDIO_COST="$test_dir/cost" \
  POST_RESPONSES="$test_dir/responses" SHOW_TRANSCRIPTION=true bash "$PROCESS_USER" "$uid_dir"
[[ ! -e "$uid_dir/request-sent" && ! -e "$uid_dir/credits_spent.txt" && ! -e "$uid_dir/operation.json" ]]
[[ -f "$uid_dir/outbox/transcription_9_1.txt" ]]
grep -Fxq 'Начали новый диалог 💜' "$uid_dir"/outbox/*.txt

new_user generating 10
printf '%s\n' 'User prompt' >"$uid_dir/inbox/9.txt"
POST_RESPONSES="$test_dir/responses" CALCULATE_TEXT_COST="$test_dir/cost" bash "$PROCESS_USER" "$uid_dir"
[[ -f "$uid_dir/inbox/10.reset" && -f "$uid_dir/ai/000001_a.json" ]]
[[ "$(<"$uid_dir/credits_spent.txt")" == 1 ]]
bash "$PROCESS_USER" "$uid_dir"
mapfile -t messages < <(cat "$uid_dir"/outbox/*.txt)
[[ "${messages[0]}" == 'Готовый ответ' && "${messages[1]}" == 'Начали новый диалог 💜' ]]
[[ ! -e "$uid_dir/inbox/10.reset" && "$(<"$uid_dir/credits_spent.txt")" == 1 ]]
