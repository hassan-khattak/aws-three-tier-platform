#!/usr/bin/env bash
# Verifies a PostgreSQL instance from inside the VPC as the application:
# trusted TLS (RDS CA + hostname), app role present and not superuser,
# read-only default on, server version. Used for restore drills and before
# moving the API to a new database generation. Exits 0 only if all pass.
#
# Usage: scripts/backup/verify-db.sh <endpoint hostname>
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export AWS_REGION="${AWS_REGION:-us-east-1}"
. "$root/scripts/runtime/lib.sh"
endpoint="${1:?usage: $0 <endpoint>}"
[[ "$endpoint" =~ ^[a-z0-9-]+\.[a-z0-9]+\.[a-z0-9-]+\.rds\.amazonaws\.com$ ]] || { echo "not an RDS endpoint: $endpoint" >&2; exit 2; }
cluster="$(tf_out cluster_name)"
log() { echo "$(date -u +%H:%M:%SZ) $*"; }

# Runs through the operator task (API image, DB CA, app credentials), with
# a read-only check script instead of the initialization helper.
verify_script='
const fs=require("fs"),tls=require("tls"),{Client}=require("pg");
const host=process.env.DBHOST,ca=fs.readFileSync(process.env.DB_CA_FILE,"utf8");
const c=new Client({host,port:5432,database:process.env.DB,user:process.env.APP_USER,password:process.env.APP_PASS,connectionTimeoutMillis:10000,ssl:{ca,rejectUnauthorized:true,checkServerIdentity:(n,cert)=>tls.checkServerIdentity(host,cert)}});
(async()=>{await c.connect();
const r=(await c.query("SELECT now() AS now, current_user AS who, version() AS v, (SELECT ssl FROM pg_stat_ssl WHERE pid=pg_backend_pid()) AS ssl, current_setting($$default_transaction_read_only$$) AS ro, (SELECT count(*)::int FROM pg_roles WHERE rolname=$$assessment_app$$ AND NOT rolsuper) AS role_ok")).rows[0];
console.log(JSON.stringify({check:"restored_db",who:r.who,ssl:r.ssl,read_only_default:r.ro,app_role_present:r.role_ok===1,server:r.v.split(" ").slice(0,2).join(" "),db_time:r.now}));
await c.end(); process.exitCode=(r.ssl&&r.ro==="on"&&r.role_ok===1)?0:1;})().catch(e=>{console.log(JSON.stringify({check:"restored_db",error:e.code||e.name}));process.exitCode=1;});'
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
node -e 'require("fs").writeFileSync(process.argv[1],JSON.stringify({containerOverrides:[{name:"operator",command:["-e",process.argv[2]],environment:[{name:"DBHOST",value:process.argv[3]}]}]}))' "$tmp/o.json" "$verify_script" "$endpoint"
subnets="$(terraform -chdir="$root/infra/stack" output -json public_subnet_ids | tr -d '[]" \n')"
task_arn="$(aws ecs run-task --cluster "$cluster" --task-definition "$(tf_out operator_task_definition)" --launch-type FARGATE \
  --network-configuration "awsvpcConfiguration={subnets=[$subnets],securityGroups=[$(tf_out api_security_group_id)],assignPublicIp=ENABLED}" \
  --overrides "file://$tmp/o.json" --started-by restore-drill --query 'tasks[0].taskArn' --output text)"
wait_task_stopped "$cluster" "$task_arn" 600 || { log "verification task did not finish"; exit 124; }
code="$(aws ecs describe-tasks --cluster "$cluster" --tasks "$task_arn" --query 'tasks[0].containers[0].exitCode' --output text)"
aws logs get-log-events --start-from-head --log-group-name "/ecs/$cluster/operator" --log-stream-name "operator/operator/${task_arn##*/}" --query 'events[].message' --output text | tr '\t' '\n'
log "verification exit=$code"
[ "$code" = "0" ]
