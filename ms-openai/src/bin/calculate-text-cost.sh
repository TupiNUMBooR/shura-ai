#!/usr/bin/env bash
# calculate-text-cost.sh
set -euo pipefail

PRICES_FILE="$(dirname "${BASH_SOURCE[0]}")/../config/model-prices.json"

main() {
  [[ $# -eq 0 ]] || { echo 'Usage: calculate-text-cost.sh < response.json' >&2; exit 2; }

  local cost
  cost="$(jq -er --slurpfile prices "$PRICES_FILE" '
    . as $r
    | ($prices[0].text[$r.model] // error("Unknown model: \($r.model)")) as $p
    | $r.usage as $u
    | ($u.input_tokens) as $input
    | ($u.output_tokens) as $output
    | ($u.input_tokens_details.cached_tokens // 0) as $cached
    | ($u.input_tokens_details.cache_write_tokens // 0) as $written
    | ($u.input_tokens_details.cache_write_tokens_details.ttl_30m_tokens // 0) as $w30
    | ($u.input_tokens_details.cache_write_tokens_details.ttl_12h_tokens // 0) as $w12
    | if ([$input,$output,$cached,$written,$w30,$w12] | all(. != null and (type == "number") and . >= 0))
         and $cached + $written <= $input
         and $w30 + $w12 == $written
         and ([$p.input,$p.cached,$p.write_30m,$p.write_12h,$p.output] | all(type == "number" and . >= 0))
      then (($input - $cached - $written) * $p.input
           + $cached * $p.cached
           + $w30 * $p.write_30m
           + $w12 * $p.write_12h
           + $output * $p.output) / 1000000
      else error("Invalid usage or prices") end
  ' )" || exit 65
  LC_NUMERIC=C printf '%.8f\n' "$cost"
}

main "$@"
