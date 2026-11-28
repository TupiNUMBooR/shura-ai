#!/usr/bin/env bash
# npd-generate-device-id.sh
set -euo pipefail

device_id=$(shuf -r -i 0-9 -n 21 | paste -sd '' -)
printf 'NPD_DEVICE_ID=%s\n' "$device_id"
