#!/usr/bin/env bash
# Backup recovery drill: restores the active database to its latest
# restorable time into a separate temporary instance, proves the restored
# copy works (TLS, roles, read-only application login), then deletes it.
# The serving database and application are not touched.
#
# Usage: scripts/backup/restore-drill.sh [--keep]   (--keep skips deletion)
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export AWS_REGION="${AWS_REGION:-us-east-1}"
. "$root/scripts/runtime/lib.sh"
keep="${1:-}"
target="three-tier-restore-drill"
source_db="$(terraform -chdir="$root/infra/stack" output -json db_generations | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>console.log(JSON.parse(s)[process.argv[1]].identifier))' "$(tf_out active_db_generation)")"
cluster="$(tf_out cluster_name)"
log() { echo "$(date -u +%H:%M:%SZ) $*"; }

restorable="$(aws rds describe-db-instances --db-instance-identifier "$source_db" --query 'DBInstances[0].LatestRestorableTime' --output text)"
log "source $source_db latest restorable time $restorable"
if aws rds describe-db-instances --db-instance-identifier "$target" >/dev/null 2>&1; then
  log "$target already exists; reusing it"
else
  aws rds restore-db-instance-to-point-in-time \
    --source-db-instance-identifier "$source_db" --target-db-instance-identifier "$target" \
    --use-latest-restorable-time \
    --db-instance-class db.t4g.micro --multi-az --storage-type gp3 \
    --db-subnet-group-name "$(aws rds describe-db-instances --db-instance-identifier "$source_db" --query 'DBInstances[0].DBSubnetGroup.DBSubnetGroupName' --output text)" \
    --vpc-security-group-ids "$(tf_out db_security_group_id)" --no-publicly-accessible \
    --db-parameter-group-name "$(aws rds describe-db-instances --db-instance-identifier "$source_db" --query 'DBInstances[0].DBParameterGroups[0].DBParameterGroupName' --output text)" \
    --ca-certificate-identifier rds-ca-rsa2048-g1 --no-auto-minor-version-upgrade --no-deletion-protection \
    --tags Key=Project,Value=three-tier Key=Purpose,Value=restore-drill Key=ManagedBy,Value=restore-drill-script \
    --query 'DBInstance.DBInstanceStatus' --output text >/dev/null
  log "restore requested"
fi
started=$(date +%s)
until [ "$(aws rds describe-db-instances --db-instance-identifier "$target" --query 'DBInstances[0].DBInstanceStatus' --output text 2>/dev/null)" = "available" ]; do
  [ $(( $(date +%s) - started )) -lt 3600 ] || { log "restore not available within 60 minutes"; exit 1; }
  sleep 30
done
log "restored instance available after $(( ($(date +%s) - started) / 60 )) min"
aws rds describe-db-instances --db-instance-identifier "$target" \
  --query 'DBInstances[0].{Endpoint:Endpoint.Address,Engine:EngineVersion,MultiAZ:MultiAZ,Encrypted:StorageEncrypted,Public:PubliclyAccessible,ParameterGroup:DBParameterGroups[0].DBParameterGroupName}' --output table
endpoint="$(aws rds describe-db-instances --db-instance-identifier "$target" --query 'DBInstances[0].Endpoint.Address' --output text)"

set +e; bash "$root/scripts/backup/verify-db.sh" "$endpoint"; code=$?; set -e
log "verification exit=$code"

if [ "$keep" = "--keep" ]; then
  log "keeping $target (--keep); delete it with: aws rds delete-db-instance --db-instance-identifier $target --skip-final-snapshot --delete-automated-backups"
else
  aws rds delete-db-instance --db-instance-identifier "$target" --skip-final-snapshot --delete-automated-backups --query 'DBInstance.DBInstanceStatus' --output text >/dev/null
  log "deletion requested; waiting"
  started=$(date +%s)
  while aws rds describe-db-instances --db-instance-identifier "$target" >/dev/null 2>&1; do
    [ $(( $(date +%s) - started )) -lt 1800 ] || { log "still deleting after 30 minutes"; break; }
    sleep 30
  done
  log "$target deleted"
fi
[ "$code" = "0" ]
