# Shared helpers for runtime scripts (sourced, not executed).

# wait_task_stopped CLUSTER TASK_ARN TIMEOUT_SECONDS
# Polls until the task is STOPPED; transient API/network errors are retried.
wait_task_stopped() {
  local cluster="$1" task="$2" timeout="$3" start status
  start=$(date +%s)
  while [ $(( $(date +%s) - start )) -lt "$timeout" ]; do
    status="$(aws ecs describe-tasks --cli-read-timeout 15 --cli-connect-timeout 10 --cluster "$cluster" --tasks "$task" --query 'tasks[0].lastStatus' --output text 2>/dev/null || echo UNREACHABLE)"
    [ "$status" = "STOPPED" ] && return 0
    sleep 6
  done
  return 1
}

# tf_out NAME  -> raw Terraform output of infra/stack
tf_out() { terraform -chdir="$root/infra/stack" output -raw "$1"; }

# wait_service_stable CLUSTER SERVICE TIMEOUT_SECONDS
# Stable = one deployment, running == desired, rollout COMPLETED.
wait_service_stable() {
  local cluster="$1" service="$2" timeout="$3" start state
  start=$(date +%s)
  while [ $(( $(date +%s) - start )) -lt "$timeout" ]; do
    state="$(aws ecs describe-services --cli-read-timeout 15 --cli-connect-timeout 10 --cluster "$cluster" --services "$service" \
      --query 'services[0].[length(deployments), runningCount, desiredCount, deployments[0].rolloutState]' --output text 2>/dev/null || echo UNREACHABLE)"
    read -r deployments running desired rollout <<<"$state"
    if [ "$deployments" = "1" ] && [ "$running" = "$desired" ] && [ "$rollout" = "COMPLETED" ]; then return 0; fi
    sleep 10
  done
  return 1
}

# Allowed services and counts. 2 is the baseline (one task per AZ); counts
# above 4 are not part of the approved sizing; 0 is only reachable via stop.sh.
valid_service() { case "$1" in web|api) return 0 ;; *) return 1 ;; esac; }
valid_count() { case "$1" in 2|3|4) return 0 ;; *) return 1 ;; esac; }

# set_count CLUSTER SERVICE COUNT -> update and wait (10 minutes)
set_count() {
  local cluster="$1" service="$2" count="$3"
  aws ecs update-service --cluster "$cluster" --service "$service" --desired-count "$count" --query 'service.desiredCount' --output text >/dev/null
  echo "$service: desired $count, waiting for a stable service..."
  if wait_service_stable "$cluster" "$service" 600; then echo "$service: stable at $count"; else echo "$service: not stable within 10 minutes" >&2; return 1; fi
}
