#!/usr/bin/env bash
# Rolling release of one service to an image digest, with verification and
# rollback. Runs in CI (AWS CLI image: no jq/node needed) and locally.
#
#   1. register a new task definition revision: the current one with only the
#      container image replaced
#   2. update the service and wait for a stable rollout (ECS replaces tasks
#      healthy-before-drain; its circuit breaker rolls back failed tasks)
#   3. smoke-test the public URL; on failure roll back to the previous revision
#
# Usage: scripts/release/deploy.sh web|api <account>.dkr.ecr.<region>.amazonaws.com/three-tier/<service>@sha256:<digest>
#        scripts/release/deploy.sh web|api --revision <task-definition ARN>
#   The second form releases a configuration revision registered by Terraform
#   (e.g. a new database endpoint). It must belong to the service's family and
#   keep the running image; the rollout, verification and rollback are the same.
# Env:   CLUSTER (default three-tier), PUBLIC_URL (default: Terraform output, if available)
set -euo pipefail
export AWS_REGION="${AWS_REGION:-us-east-1}"
usage="usage: $0 web|api <image@sha256:digest> | --revision <task-definition-arn>"
service="${1:?$usage}"
cluster="${CLUSTER:-three-tier}"
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
log() { echo "$(date -u +%H:%M:%SZ) [$service] $*"; }

case "$service" in web|api) ;; *) echo "service must be web or api" >&2; exit 2 ;; esac
mode=image; image=""; candidate=""
if [ "${2:-}" = "--revision" ]; then
  mode=revision; candidate="${3:?$usage}"
  [[ "$candidate" =~ ^arn:aws:ecs:[a-z0-9-]+:[0-9]{12}:task-definition/three-tier-${service}:[0-9]+$ ]] \
    || { echo "revision must be a three-tier-$service task definition ARN" >&2; exit 2; }
else
  image="${2:?$usage}"
  [[ "$image" =~ ^[0-9]{12}\.dkr\.ecr\.[a-z0-9-]+\.amazonaws\.com/three-tier/${service}@sha256:[0-9a-f]{64}$ ]] \
    || { echo "image must be this service's ECR repository pinned by digest" >&2; exit 2; }
fi
if [ -z "${PUBLIC_URL:-}" ] && command -v terraform >/dev/null 2>&1; then
  PUBLIC_URL="$(terraform -chdir="$root/infra/stack" output -raw public_base_url 2>/dev/null || true)"
fi

previous="$(aws ecs describe-services --cluster "$cluster" --services "$service" --query 'services[0].taskDefinition' --output text)"
current_image="$(aws ecs describe-task-definition --task-definition "$previous" --query 'taskDefinition.containerDefinitions[0].image' --output text)"
log "running $previous with $current_image"

if [ "$mode" = revision ]; then
  # Configuration release: validate before touching the service.
  read -r status candidate_image < <(aws ecs describe-task-definition --task-definition "$candidate" \
    --query 'taskDefinition.[status, containerDefinitions[0].image]' --output text)
  [ "$status" = ACTIVE ] || { echo "revision $candidate is $status" >&2; exit 2; }
  [ "$candidate" != "$previous" ] || { echo "revision $candidate is already running" >&2; exit 2; }
  [ "$candidate_image" = "$current_image" ] \
    || { echo "revision changes the image ($candidate_image); configuration releases must keep $current_image" >&2; exit 2; }
  next="$candidate"
  log "configuration release of $next (image unchanged)"
  aws ecs describe-task-definition --task-definition "$previous" --query 'taskDefinition.containerDefinitions[0].environment' --output text | sort > "/tmp/.deploy-env-old.$$" || true
  aws ecs describe-task-definition --task-definition "$next" --query 'taskDefinition.containerDefinitions[0].environment' --output text | sort > "/tmp/.deploy-env-new.$$" || true
  log "environment change: $( (diff "/tmp/.deploy-env-old.$$" "/tmp/.deploy-env-new.$$" || true) | grep -E '^[<>]' | tr '\t' '=' | tr '\n' ' ')"
  rm -f "/tmp/.deploy-env-old.$$" "/tmp/.deploy-env-new.$$"
else
  # Image release: copy the registrable fields of the running revision and swap the image.
  tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
  aws ecs describe-task-definition --task-definition "$previous" --output json --query 'taskDefinition.{
    family: family, taskRoleArn: taskRoleArn, executionRoleArn: executionRoleArn, networkMode: networkMode,
    containerDefinitions: containerDefinitions, requiresCompatibilities: requiresCompatibilities,
    cpu: cpu, memory: memory, runtimePlatform: runtimePlatform}' > "$tmp/td.json"
  [ "$(grep -c "\"$current_image\"" "$tmp/td.json")" = "1" ] || { echo "unexpected task definition shape" >&2; exit 1; }
  sed "s|\"$current_image\"|\"$image\"|" "$tmp/td.json" > "$tmp/new.json"
  next="$(aws ecs register-task-definition --cli-input-json "file://$tmp/new.json" --query 'taskDefinition.taskDefinitionArn' --output text)"
  log "registered $next"
fi

rollback() {
  log "ROLLBACK to $previous: $1"
  aws ecs update-service --cluster "$cluster" --service "$service" --task-definition "$previous" --query 'service.serviceName' --output text >/dev/null
  wait_rollout "$previous" || true
  exit 1
}

# Stable = one deployment on the expected revision, running == desired.
wait_rollout() {
  local want="$1" start state
  start=$(date +%s)
  while [ $(( $(date +%s) - start )) -lt 900 ]; do
    state="$(aws ecs describe-services --cli-read-timeout 15 --cli-connect-timeout 10 --cluster "$cluster" --services "$service" \
      --query 'services[0].[length(deployments), deployments[0].taskDefinition, deployments[0].rolloutState, runningCount, desiredCount]' --output text 2>/dev/null || echo UNREACHABLE)"
    read -r n td rollout running desired <<<"$state"
    [ "$rollout" = "FAILED" ] && return 2
    if [ "$n" = "1" ] && [ "$td" = "$want" ] && [ "$rollout" = "COMPLETED" ] && [ "$running" = "$desired" ]; then return 0; fi
    # The circuit breaker rolled back on its own.
    if [ "$n" = "1" ] && [ "$td" != "$want" ] && [ "$rollout" = "COMPLETED" ]; then return 3; fi
    sleep 10
  done
  return 1
}

aws ecs update-service --cluster "$cluster" --service "$service" --task-definition "$next" --query 'service.serviceName' --output text >/dev/null
log "rolling out (healthy-before-drain, max 15 minutes)"
set +e; wait_rollout "$next"; result=$?; set -e
case "$result" in
  0) log "rollout complete" ;;
  2|3) log "ECS circuit breaker failed the deployment"; rollback "new tasks did not become healthy" ;;
  *) rollback "rollout did not stabilize within 15 minutes" ;;
esac

if [ -n "${PUBLIC_URL:-}" ]; then
  log "smoke test $PUBLIC_URL"
  ok=1
  page="$(curl -fsS --max-time 15 "$PUBLIC_URL/" || ok=0)"
  status="$(curl -fsS --max-time 15 "$PUBLIC_URL/api/status" || ok=0)"
  printf '%s' "$page" | grep -q "Welcome, it's " || ok=0
  printf '%s' "$status" | grep -Eq '"request_uuid":"[0-9a-f-]{36}"' || ok=0
  [ "$ok" = 1 ] || rollback "public smoke test failed"
  log "smoke test passed"
else
  log "PUBLIC_URL not set; skipped smoke test"
fi
log "released ${image:-$current_image (configuration only)} as $next (previous $previous)"
