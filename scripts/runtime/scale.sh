#!/usr/bin/env bash
# Scale one service to an approved count and wait until it is stable.
# Never part of an ordinary release. Usage: scripts/runtime/scale.sh web|api 2|3|4
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export AWS_REGION="${AWS_REGION:-us-east-1}"
. "$root/scripts/runtime/lib.sh"
[ $# -eq 2 ] || { echo "Usage: $0 web|api 2|3|4" >&2; exit 2; }
valid_service "$1" || { echo "Unknown service '$1' (web or api)" >&2; exit 2; }
valid_count "$2" || { echo "Count '$2' not allowed (2-4; use stop.sh for 0)" >&2; exit 2; }
set_count "$(tf_out cluster_name)" "$1" "$2"
