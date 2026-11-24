#!/usr/bin/env bash
# server-deploy.sh
set -euo pipefail

SCRIPT_NAME="$(basename "$0")"
ssh_dir=""
ssh_socket=""

main() {
  if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    printf 'Usage: %s\nRun from the project root with SSH_ADDRESS and REMOTE_DIR in .env.\nCopies deploy/compose.yml and deploy/.env, then deploys locally built images over SSH.\n' "$SCRIPT_NAME"
    return 0
  fi
  [[ $# -eq 0 ]] || error 2 "Unexpected arguments"

  local required
  for required in .env compose.yml deploy/compose.yml deploy/.env; do
    [[ -f "$required" ]] || error 66 "Missing file: $required"
  done
  source ./.env
  [[ -n "${SSH_ADDRESS:-}" ]] || error 66 "SSH_ADDRESS is required"
  [[ "${REMOTE_DIR:-}" == /* ]] || error 78 "REMOTE_DIR must be an absolute path"

  local description version dirty config images source image remote_dir version_value
  description=$(git describe --tags --long --abbrev=8 --match '[0-9]*.[0-9]*.[0-9]*') \
    || error 66 "No reachable release tag"
  [[ "$description" =~ ^([0-9]+\.[0-9]+\.[0-9]+)-([0-9]+)-(g[0-9a-f]+)$ ]] \
    || error 78 "Expected a release tag in X.Y.Z format: $description"
  version="${BASH_REMATCH[1]}-dev.${BASH_REMATCH[2]}.${BASH_REMATCH[3]}"
  dirty=$(git status --porcelain)
  [[ -z "$dirty" ]] || version+=.dirty

  ssh_dir=$(mktemp -d /tmp/server-deploy.XXXXXXXX)
  ssh_socket="$ssh_dir/ssh"
  trap cleanup EXIT

  log "Connect to $SSH_ADDRESS"
  ssh -M -N -f -o ControlPersist=yes -o ControlPath="$ssh_socket" -- "$SSH_ADDRESS"

  local -a ssh_opts=(-o ControlMaster=no -o ControlPath="$ssh_socket" -o BatchMode=yes)
  local rsync_ssh="ssh -o ControlMaster=no -o ControlPath=$ssh_socket -o BatchMode=yes"

  config=$(VERSION="$version" docker compose --env-file deploy/.env -f deploy/compose.yml \
    config --no-path-resolution --format json)
  images=$(jq -er --arg suffix ":$version" '
    [.services[].image] | unique |
    if length > 0 and all(.[]; type == "string" and endswith($suffix))
    then .[] else error("Expected deploy images tagged " + $suffix) end
  ' <<<"$config")
  local -a deploy_images save_images bind_dirs=()
  mapfile -t deploy_images <<<"$images"

  local bind_sources
  bind_sources=$(jq -r '
    [.services[].volumes[]? | select(.type == "bind") | .source |
      select(startswith("/") | not)] | unique[]
  ' <<<"$config")
  remote_dir=$(shell_quote "$REMOTE_DIR")
  version_value=$(shell_quote "$version")
  while IFS= read -r source; do
    [[ -n "$source" ]] || continue
    [[ "/$source/" != */../* ]] || error 78 "Bind source leaves deployment directory: $source"
    bind_dirs+=("$(shell_quote "$REMOTE_DIR/$source")")
  done <<<"$bind_sources"

  log "Build $version"
  VERSION="$version" docker compose -f compose.yml build
  for image in "${deploy_images[@]}"; do
    docker image tag "$image" "${image%:*}:latest"
    save_images+=("$image" "${image%:*}:latest")
  done

  log "Upload Compose and environment"
  ssh "${ssh_opts[@]}" -- "$SSH_ADDRESS" "mkdir -p -- $remote_dir ${bind_dirs[*]}"
  rsync -a -s -e "$rsync_ssh" --chmod=F600 -- deploy/compose.yml deploy/.env "$SSH_ADDRESS:${REMOTE_DIR%/}/"

  log "Upload images"
  docker image save "${save_images[@]}" | gzip | ssh "${ssh_opts[@]}" -- "$SSH_ADDRESS" 'docker image load'

  log "Restart services"
  ssh "${ssh_opts[@]}" -- "$SSH_ADDRESS" "cd $remote_dir && VERSION=$version_value sh -s" <<'REMOTE'
set -eu
version_file=$(mktemp .VERSION.XXXXXXXX)
trap 'rm -f -- "$version_file"' EXIT
printf '%s\n' "$VERSION" > "$version_file"
mv -f -- "$version_file" VERSION.txt

docker compose -f compose.yml config --quiet
docker compose -f compose.yml down
docker compose -f compose.yml up -d --no-build --pull never --remove-orphans
docker compose -f compose.yml ps
REMOTE

  log "Follow logs"
  ssh -t "${ssh_opts[@]}" -- "$SSH_ADDRESS" \
    "cd $remote_dir || exit; VERSION=$version_value docker compose -f compose.yml logs -f --tail=200; exec \"\${SHELL:-/bin/sh}\" -l"
}

# region functions

cleanup() {
  ssh -o ControlPath="$ssh_socket" -O exit -- "$SSH_ADDRESS" >/dev/null 2>&1 || true
  rm -rf -- "$ssh_dir"
}

shell_quote() { printf "'%s'" "${1//\'/\'\\\'\'}"; }
log() { printf '[%s] [%s] %s\n' "$(date -u +%FT%TZ)" "$SCRIPT_NAME" "$*" >&2; }
error() { local code="$1"; shift; log "[ERROR] $*"; exit "$code"; }

# endregion

main "$@"
