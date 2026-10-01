#!/usr/bin/env bash
# Runs the one-off private probe inside the VPC (probe security group, ALB
# access only) and exits with its result. Checks /, /api/status and
# /health/ready through the internal load balancer.
#
# Usage: scripts/runtime/probe.sh [--url http://alternative-target]
#   --url probes another in-VPC base URL (e.g. a new target before release).
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export AWS_REGION="${AWS_REGION:-us-east-1}"
out() { terraform -chdir="$root/infra/stack" output -raw "$1"; }

url=""
if [ "${1:-}" = "--url" ]; then
  url="${2:?--url needs a value}"
  [[ "$url" =~ ^http://[A-Za-z0-9.-]+(:[0-9]+)?$ ]] || { echo "Invalid --url (http://host[:port] only)" >&2; exit 2; }
elif [ $# -gt 0 ]; then
  echo "Usage: $0 [--url http://host[:port]]" >&2; exit 2
fi

cluster="$(out cluster_name)"
task_definition="$(out probe_task_definition)"
subnets="$(terraform -chdir="$root/infra/stack" output -json public_subnet_ids | tr -d '[]" \n')"
security_group="$(out probe_security_group_id)"
overrides='{}'
[ -n "$url" ] && overrides="{\"containerOverrides\":[{\"name\":\"probe\",\"environment\":[{\"name\":\"PROBE_URL\",\"value\":\"$url\"}]}]}"

task_arn="$(aws ecs run-task --cluster "$cluster" --task-definition "$task_definition" --launch-type FARGATE \
  --network-configuration "awsvpcConfiguration={subnets=[$subnets],securityGroups=[$security_group],assignPublicIp=ENABLED}" \
  --overrides "$overrides" --started-by probe --query 'tasks[0].taskArn' --output text)"
task_id="${task_arn##*/}"
echo "probe task $task_id started"
# Bounded wait (10 minutes). Polling tolerates brief network drops on the
# operator's side; a probe still running at the deadline is stopped.
. "$root/scripts/runtime/lib.sh"
if ! wait_task_stopped "$cluster" "$task_arn" 600; then
  aws ecs stop-task --cluster "$cluster" --task "$task_arn" --reason "probe timeout" >/dev/null 2>&1 || true
  echo "probe timed out" >&2; exit 124
fi
read -r exit_code stop_reason < <(aws ecs describe-tasks --cluster "$cluster" --tasks "$task_arn" \
  --query 'tasks[0].[containers[0].exitCode, stoppedReason]' --output text)
aws logs get-log-events --start-from-head --log-group-name "/ecs/$cluster/operator" --log-stream-name "probe/probe/$task_id" \
  --query 'events[].message' --output text 2>/dev/null | tr '\t' '\n' || echo "(log not available)"
echo "probe exit=$exit_code ($stop_reason)"
[ "$exit_code" = "0" ]
