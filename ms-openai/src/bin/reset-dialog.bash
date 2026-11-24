# Shared by the inbox worker and the response worker.
RESET_APPLIED=10

reset_pending() {
  local file seq latest=0
  reset_marker=
  for file in "$1"/inbox/*.reset; do
    [[ -f "$file" && ${file##*/} =~ ^[0-9]+\.reset$ ]] || continue
    seq="${file##*/}"
    seq="${seq%.reset}"
    if (( 10#$seq > latest )); then
      latest=$((10#$seq))
      reset_marker="$file"
    fi
  done
  [[ -n "$reset_marker" ]]
}

apply_reset() {
  local uid_dir="$1" marker="$reset_marker" file name seq tmp
  local cutoff="${marker##*/}" previous=0
  cutoff="${cutoff%.reset}"
  if [[ -f "$uid_dir/reset_seq.txt" ]]; then
    previous="$(<"$uid_dir/reset_seq.txt")"
  fi

  # Keep the marker until all cleanup and notification writes succeed.
  for file in "$uid_dir"/inbox/* "$uid_dir"/inbox-delayed/*; do
    [[ -f "$file" && "$file" != "$marker" ]] || continue
    name="${file##*/}"
    seq="${name%%.*}"
    [[ "$seq" =~ ^[0-9]+$ ]] || continue
    if (( 10#$seq < 10#$cutoff )); then rm -f -- "$file"; fi
  done
  if (( 10#$cutoff > 10#$previous )); then
    rm -rf -- "$uid_dir/ai"
    rm -f -- "$uid_dir/operation.json" "$uid_dir"/.operation.* "$uid_dir"/.tmp.*
    mkdir -p -- "$uid_dir/ai" "$uid_dir/outbox"
    write_outbox "$uid_dir/outbox" 'Начали новый диалог 💜'

    # A poll may be retried after the marker has already been consumed.
    tmp="$(mktemp "$uid_dir/.tmp.XXXXXX")"
    printf '%s\n' "$cutoff" >"$tmp"
    mv -f -- "$tmp" "$uid_dir/reset_seq.txt"
  fi
  rm -f -- "$marker"
}

write_outbox() {
  local dir="$1" value="$2" tmp dest base file suffix=0 number
  tmp="$(mktemp "$dir/.out.XXXXXX")"
  printf '%s\n' "$value" >"$tmp"
  base="$EPOCHREALTIME"
  base="${base/./}"
  base="${base:0:${#base}-3}"
  for file in "$dir/$base"-*.txt; do
    [[ ${file##*/} =~ ^[0-9]+-([0-9]{6})\.txt$ ]] || continue
    number=$((10#${BASH_REMATCH[1]} + 1))
    if (( number > suffix )); then suffix="$number"; fi
  done
  printf -v dest '%s/%s-%06d.txt' "$dir" "$base" "$suffix"
  mv -f -- "$tmp" "$dest"
}
