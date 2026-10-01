#!/usr/bin/env bash
# Failure test: samples the private request path continuously while one
# failure is injected, then reports request outcomes with ECS/RDS events.
#
# Usage: tests/system/resilience/run.sh task-web|task-api|db-failover|release-web|release-api|config-web|config-api [duration_s]
#   task-*      stops one running task; ECS must replace it.
#   db-failover forces a Multi-AZ failover (reboot with failover). Requires
#               explicit authorization; causes a brief database interruption.
#   release-*   rolling release of the image in deploy/images.json through
#               scripts/release/deploy.sh (new revision, healthy-before-drain).
#   config-*    configuration release of the revision Terraform registered
#               (deploy.sh --revision), e.g. moving the API to a new database.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
export AWS_REGION="${AWS_REGION:-us-east-1}"
. "$root/scripts/runtime/lib.sh"
action="${1:?usage: $0 task-web|task-api|db-failover [duration_s]}"
duration="${2:-240}"
case "$action" in task-web|task-api|db-failover|release-web|release-api|config-web|config-api) ;; *) echo "unknown action $action" >&2; exit 2 ;; esac

cluster="$(tf_out cluster_name)"
subnets="$(terraform -chdir="$root/infra/stack" output -json public_subnet_ids | tr -d '[]" \n')"
db="$(terraform -chdir="$root/infra/stack" output -json db_generations | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>console.log(JSON.parse(s)[process.argv[1]].identifier))' "$(tf_out active_db_generation)")"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
node -e 'const fs=require("fs");const [file,d,src]=process.argv.slice(1);fs.writeFileSync(file+"/o.json",JSON.stringify({containerOverrides:[{name:"probe",command:[fs.readFileSync(src,"utf8")],environment:[{name:"DURATION_S",value:d},{name:"INTERVAL_MS",value:"500"}]}]}))' "$tmp" "$duration" "$root/tests/system/resilience/sampler.js"

started_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
task_arn="$(aws ecs run-task --cluster "$cluster" --task-definition "$(tf_out probe_task_definition)" --launch-type FARGATE \
  --network-configuration "awsvpcConfiguration={subnets=[$subnets],securityGroups=[$(tf_out probe_security_group_id)],assignPublicIp=ENABLED}" \
  --overrides "file://$tmp/o.json" --started-by "resilience-$action" --query 'tasks[0].taskArn' --output text)"
task_id="${task_arn##*/}"
echo "sampler $task_id started at $started_at for ${duration}s"
# Bounded wait for the sampler to run; each status call has its own timeout so
# a dropped connection on the operator's side cannot hang the test.
deadline=$(( $(date +%s) + 300 ))
while :; do
  state="$(aws ecs describe-tasks --cli-read-timeout 15 --cli-connect-timeout 10 --cluster "$cluster" --tasks "$task_arn" --query 'tasks[0].lastStatus' --output text 2>/dev/null || echo UNREACHABLE)"
  [ "$state" = RUNNING ] && break
  [ "$state" = STOPPED ] && { echo "sampler stopped before the test started" >&2; exit 1; }
  [ "$(date +%s)" -lt "$deadline" ] || { echo "sampler not running within 5 minutes (last state: $state)" >&2; aws ecs stop-task --cluster "$cluster" --task "$task_arn" >/dev/null 2>&1 || true; exit 124; }
  sleep 5
done
echo "sampler running; baseline 30 s"; sleep 30

injected_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
case "$action" in
  task-web|task-api)
    service="${action#task-}"
    victim="$(aws ecs list-tasks --cluster "$cluster" --service-name "$service" --desired-status RUNNING --query 'taskArns[0]' --output text)"
    aws ecs stop-task --cluster "$cluster" --task "$victim" --reason "resilience test" --query 'task.taskArn' --output text >/dev/null
    echo "$injected_at stopped $service task ${victim##*/}"
    ;;
  release-web|release-api)
    service="${action#release-}"
    image="$(node -e 'console.log(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"))[process.argv[2]].image)' "$root/deploy/images.json" "$service")"
    echo "$injected_at releasing $service $image"
    bash "$root/scripts/release/deploy.sh" "$service" "$image"
    ;;
  config-web|config-api)
    service="${action#config-}"
    revision="$(terraform -chdir="$root/infra/stack" output -json service_task_definitions | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>console.log(JSON.parse(s)[process.argv[1]]))' "$service")"
    echo "$injected_at configuration release of $service $revision"
    bash "$root/scripts/release/deploy.sh" "$service" --revision "$revision"
    ;;
  db-failover)
    before="$(aws rds describe-db-instances --db-instance-identifier "$db" --query 'DBInstances[0].[AvailabilityZone,SecondaryAvailabilityZone]' --output text)"
    aws rds reboot-db-instance --db-instance-identifier "$db" --force-failover --query 'DBInstance.DBInstanceStatus' --output text >/dev/null
    echo "$injected_at forced failover of $db (primary/standby AZ before: $before)"
    ;;
esac

wait_task_stopped "$cluster" "$task_arn" $(( duration + 300 )) || { echo "sampler did not finish" >&2; exit 124; }
exit_code="$(aws ecs describe-tasks --cluster "$cluster" --tasks "$task_arn" --query 'tasks[0].containers[0].exitCode' --output text)"
echo "--- sampler log (failures and summary)"
aws logs get-log-events --start-from-head --log-group-name "/ecs/$cluster/operator" --log-stream-name "probe/probe/$task_id" \
  --query 'events[].message' --output text | tr '\t' '\n' | grep -E '"fail"|"sampler"' | tail -60
echo "--- ECS service events since $started_at"
for s in web api; do
  aws ecs describe-services --cluster "$cluster" --services "$s" --query 'services[0].events[].[createdAt,message]' --output json |
    node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{const from=Date.parse(process.argv[1]);for(const[t,m]of JSON.parse(s).filter(([t])=>Date.parse(t)>=from).sort())console.log("  "+new Date(t).toISOString()+" "+m.slice(0,160))})' "$started_at"
done
if [ "$action" = db-failover ]; then
  echo "--- RDS events since $started_at"
  aws rds describe-events --source-type db-instance --source-identifier "$db" --start-time "$started_at" --query 'Events[].[Date,Message]' --output text | sed 's/^/  /'
  echo "primary/standby AZ after: $(aws rds describe-db-instances --db-instance-identifier "$db" --query 'DBInstances[0].[AvailabilityZone,SecondaryAvailabilityZone]' --output text)"
fi
echo "--- service state now"
for s in web api; do echo "  $s: $(aws ecs describe-services --cluster "$cluster" --services "$s" --query 'services[0].[runningCount,desiredCount]' --output text) (running desired)"; done
echo "sampler exit=$exit_code (0 = path ended healthy, no open outage)"
