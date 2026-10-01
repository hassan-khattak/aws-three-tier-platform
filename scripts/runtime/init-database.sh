#!/usr/bin/env bash
# Initializes the application database role through a one-off ECS operator
# task, then prints the task's (secret-free) log and exits with its code.
# Rerunnable: an existing application password in Secrets Manager is kept.
#
# Usage: scripts/runtime/init-database.sh
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export AWS_REGION="${AWS_REGION:-us-east-1}"
out() { terraform -chdir="$root/infra/stack" output -raw "$1"; }
outj() { terraform -chdir="$root/infra/stack" output -json "$1"; }

cluster="$(out cluster_name)"
task_definition="$(out operator_task_definition)"
secret="$(out db_app_secret_arn)"
subnets="$(outj public_subnet_ids | tr -d '[]" \n')"
security_group="$(out api_security_group_id)"
[ -n "$task_definition" ] && [ "$task_definition" != "null" ] || { echo "No operator task definition; push the API image first." >&2; exit 1; }

# 1. Application password: generated locally once, written from a private
#    file (never a command-line argument), never printed.
if [ "$(aws secretsmanager list-secret-version-ids --secret-id "$secret" --query 'length(Versions)' --output text)" = "0" ]; then
  tmp="$(mktemp -d)"; chmod 700 "$tmp"; trap 'rm -rf "$tmp"' EXIT
  python3 -c 'import json,secrets; print(json.dumps({"username": "assessment_app", "password": secrets.token_urlsafe(32)}))' > "$tmp/secret.json"
  aws secretsmanager put-secret-value --secret-id "$secret" --secret-string "file://$tmp/secret.json" --query VersionId --output text >/dev/null
  rm -f "$tmp/secret.json"
  echo "Application secret initialized."
else
  echo "Application secret already set; keeping it."
fi

# 2. One-off task in a public subnet with the API security group.
task_arn="$(aws ecs run-task --cluster "$cluster" --task-definition "$task_definition" --launch-type FARGATE --count 1 \
  --network-configuration "awsvpcConfiguration={subnets=[$subnets],securityGroups=[$security_group],assignPublicIp=ENABLED}" \
  --started-by db-init --query 'tasks[0].taskArn' --output text)"
task_id="${task_arn##*/}"
echo "Started operator task $task_id; waiting (up to 10 minutes)..."
. "$root/scripts/runtime/lib.sh"
wait_task_stopped "$cluster" "$task_arn" 600 || { echo "operator task did not finish in time" >&2; exit 124; }

read -r exit_code stop_reason < <(aws ecs describe-tasks --cluster "$cluster" --tasks "$task_arn" \
  --query 'tasks[0].[containers[0].exitCode, stoppedReason]' --output text)
echo "--- operator log"
aws logs get-log-events --start-from-head --log-group-name "/ecs/$(out cluster_name)/operator" --log-stream-name "operator/operator/$task_id" \
  --query 'events[].message' --output text 2>/dev/null | tr '\t' '\n' || echo "(log not available)"
echo "--- task $task_id exit=$exit_code reason=$stop_reason"
[ "$exit_code" = "0" ]
