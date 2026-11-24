#!/usr/bin/env bash
# reset-dialog.sh - Apply the latest pending reset for one user.
#
# process-inbox.sh stops when it sees a marker and leaves it in place.
# process-user.sh then calls this script and ends the current pass.
# Exit 0 means the marker was handled. Other statuses are errors.
set -euo pipefail

SCRIPT_NAME="$(basename "$0")"

main() {
  [[ $# -eq 1 ]] || error 2 "Usage: $SCRIPT_NAME UID_DIR"
  local uid_dir="$1" marker="" file name seq tmp cutoff=0 previous=0
  [[ -d "$uid_dir/inbox" ]] || error 66 "Inbox not found: $uid_dir/inbox"

  for file in "$uid_dir"/inbox/*.reset; do
    [[ -f "$file" ]] || continue
    name="${file##*/}"
    [[ "$name" =~ ^([0-9]+)\.reset$ ]] || continue
    seq=$((10#${BASH_REMATCH[1]}))
    if [[ -z "$marker" ]] || (( seq > cutoff )); then
      cutoff="$seq"
      marker="$file"
    fi
  done
  [[ -n "$marker" ]] || error 66 "Reset marker not found: $uid_dir/inbox"

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

# region functions

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

error() {
  local code="$1"
  shift
  printf '[%s] [%s] [ERROR] %s\n' "$(date -u +%FT%TZ)" "$SCRIPT_NAME" "$*" >&2
  exit "$code"
}

# endregion

main "$@"
