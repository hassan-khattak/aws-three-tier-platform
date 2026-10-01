#!/usr/bin/env bash
# Stop the application (both services to 0 tasks). THIS IS A LIVE OUTAGE:
# the public site and API return errors until start.sh runs. The database,
# load balancer and CDN keep running. Usage: scripts/runtime/stop.sh --confirm-outage
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export AWS_REGION="${AWS_REGION:-us-east-1}"
. "$root/scripts/runtime/lib.sh"
[ "${1:-}" = "--confirm-outage" ] || { echo "Refusing: stopping causes a live outage. Rerun with --confirm-outage." >&2; exit 2; }
cluster="$(tf_out cluster_name)"
for service in web api; do
  aws ecs update-service --cluster "$cluster" --service "$service" --desired-count 0 --query 'service.desiredCount' --output text >/dev/null
  wait_service_stable "$cluster" "$service" 600 && echo "$service: stopped (0 tasks)" || { echo "$service: did not stop within 10 minutes" >&2; exit 1; }
done
echo "Application STOPPED. Restore with scripts/runtime/start.sh"
