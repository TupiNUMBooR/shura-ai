#!/usr/bin/env bash
# bash-brick-example.sh
set -Eeuo pipefail

SCRIPT_NAME="$(basename "$0")"

# required environment
EXAMPLE_VALUE="${EXAMPLE_VALUE:-}"

# optional environment
VERBOSE="${VERBOSE:-0}"

main() {
  handle_help "$@"

  [[ $# -eq 1 ]] || error 2 "Expected message"
  [[ -n "$EXAMPLE_VALUE" ]] || error 78 "EXAMPLE_VALUE is required"

  local message="$1"

  if [[ -z "${message//[[:space:]]/}" ]]; then
    warn "Message is empty"
  fi

  if [[ "$VERBOSE" == "1" ]]; then
    log "echo: example_value=$EXAMPLE_VALUE chars=${#message}"
  fi

  printf '%s\n' "$message"
}

usage() {
  cat <<EOF_USAGE
$SCRIPT_NAME — example Bash brick that prints a message.

Usage:
  $SCRIPT_NAME <message>
  $SCRIPT_NAME -h|--help

Arguments:
  message        Text to print (empty/whitespace-only text warns).

Environment:
  EXAMPLE_VALUE  Required, non-empty.
  VERBOSE        Log additional details when set to 1 (default: 0).

Exit codes:
  0    Success (warnings do not change the exit code).
  2    Invalid number of arguments.
  78   EXAMPLE_VALUE is missing or empty.
  127  Required command is unavailable.

Example:
  EXAMPLE_VALUE=example $SCRIPT_NAME "Hello, world!"
EOF_USAGE
}

# Exit-code conventions for derived Bash bricks (not this script's --help):
#   0       Success; warnings may still be emitted to stderr.
#   2       Invalid command-line arguments (project convention).
#   10-63   Project-specific failures (assign meanings per brick), e.g.:
#           long-running local operation failed; paid operation failed;
#           critical operation failed; output already exists.
#   64      Usage error (sysexits; alternative to 2).
#   65      Invalid input data (sysexits EX_DATAERR).
#   66      Input cannot be opened (sysexits EX_NOINPUT).
#   69      Required service unavailable (sysexits EX_UNAVAILABLE).
#   70      Internal software error (sysexits EX_SOFTWARE).
#   73      Cannot create output (sysexits EX_CANTCREAT).
#   75      Temporary failure; retry may help (sysexits EX_TEMPFAIL).
#   78      Configuration error (sysexits EX_CONFIG).
#   126     Command found but cannot execute (shell convention).
#   127     Command not found (shell convention).
# Choose only codes relevant to a new brick; document actual return codes in
# its usage(). These are conventions, not a claim that Bash reserves 10-19.

# region functions

handle_help() {
  if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
  fi
}

log() {
  printf '[%s] [%s] %s\n' \
    "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
    "$SCRIPT_NAME" \
    "$*" >&2
}

warn() {
  log "[WARN] $*"
}

error() {
  local code="$1"
  shift

  log "[ERROR] $*"
  exit "$code"
}

# endregion

main "$@"
