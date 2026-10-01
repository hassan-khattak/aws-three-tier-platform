#!/usr/bin/env bash
# Restore both services to the baseline of 2 tasks each and wait.
# Usage: scripts/runtime/start.sh
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export AWS_REGION="${AWS_REGION:-us-east-1}"
. "$root/scripts/runtime/lib.sh"
cluster="$(tf_out cluster_name)"
# API first: web's readiness depends on it.
set_count "$cluster" api 2
set_count "$cluster" web 2
