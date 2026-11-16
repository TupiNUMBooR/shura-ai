#!/usr/bin/env bash
# calculate-audio-cost.sh
set -euo pipefail

PRICES_FILE="${PRICES_FILE:-$(dirname "${BASH_SOURCE[0]}")/../../config/prices.json}"

main() {
  [[ $# -eq 1 ]] || { echo 'Usage: calculate-audio-cost.sh MODEL < response.json' >&2; exit 2; }

  local cost
  cost="$(jq -er --arg model "$1" --slurpfile prices "$PRICES_FILE" '
    ($prices[0].audio[$model] // error("Unknown model: \($model)")) as $rate
    | .usage as $u
    | if $u.type == "duration"
         and ($u.seconds | type == "number" and . >= 0)
         and ($rate | type == "number" and . >= 0)
      then $u.seconds * $rate / 60
      else error("Invalid audio usage or price") end
  ' )"
  LC_NUMERIC=C printf '%.8f\n' "$cost"
}

main "$@"
