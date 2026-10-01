#!/usr/bin/env bash
# One-command overview: services, target health, task placement, images,
# database and public URL. Read-only. Usage: scripts/runtime/status.sh
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export AWS_REGION="${AWS_REGION:-us-east-1}"
. "$root/scripts/runtime/lib.sh"
cluster="$(tf_out cluster_name)"
echo "== Services"
aws ecs describe-services --cluster "$cluster" --services web api \
  --query 'services[].{Service:serviceName,Desired:desiredCount,Running:runningCount,Rollout:deployments[0].rolloutState,TaskDef:taskDefinition}' --output table
echo "== Target health"
terraform -chdir="$root/infra/stack" output -json target_group_arns | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{for(const[k,v]of Object.entries(JSON.parse(s)))console.log(k+" "+v)})' |
while read -r service arn; do
  printf '%s: ' "$service"
  aws elbv2 describe-target-health --target-group-arn "$arn" --query 'TargetHealthDescriptions[].[Target.AvailabilityZone,TargetHealth.State]' --output text | tr '\t\n' ': ' ; echo
done
echo "== Running images"
for service in web api; do
  td="$(aws ecs describe-services --cluster "$cluster" --services "$service" --query 'services[0].taskDefinition' --output text)"
  echo "$service: $(aws ecs describe-task-definition --task-definition "$td" --query 'taskDefinition.containerDefinitions[0].image' --output text)"
done
echo "== Database"
db="$(terraform -chdir="$root/infra/stack" output -json db_generations | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{const g=JSON.parse(s);for(const[k,v]of Object.entries(g))console.log(k+" "+v.identifier)})')"
while read -r generation identifier; do
  aws rds describe-db-instances --db-instance-identifier "$identifier" \
    --query "DBInstances[0].{Generation:'$generation',Id:DBInstanceIdentifier,Status:DBInstanceStatus,Engine:EngineVersion,MultiAZ:MultiAZ,LatestRestorable:LatestRestorableTime}" --output table
done <<<"$db"
echo "active generation: $(tf_out active_db_generation)"
echo "== Public URL"
tf_out public_base_url 2>/dev/null || echo "(no CDN yet)"
echo
