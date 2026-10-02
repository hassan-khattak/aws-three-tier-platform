#!/usr/bin/env bash
# On-demand backup of all mutable storage, in addition to the daily schedules:
#   - a manual snapshot of the active database generation
#   - an AWS Backup job for the Terraform state bucket
# Waits for both (bounded) and prints their identifiers. Manual DB snapshots
# are kept until deleted; teardown lists them.
#
# Usage: scripts/backup/backup-now.sh
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export AWS_REGION="${AWS_REGION:-us-east-1}"
. "$root/scripts/runtime/lib.sh"
log() { echo "$(date -u +%H:%M:%SZ) $*"; }
stamp="$(date -u +%Y%m%d-%H%M%S)"

generation="$(tf_out active_db_generation)"
db="$(terraform -chdir="$root/infra/stack" output -json db_generations | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>console.log(JSON.parse(s)[process.argv[1]].identifier))' "$generation")"
snapshot="$db-manual-$stamp"
aws rds create-db-snapshot --db-instance-identifier "$db" --db-snapshot-identifier "$snapshot" \
  --tags Key=Project,Value=three-tier Key=Purpose,Value=on-demand-backup --query 'DBSnapshot.Status' --output text >/dev/null
log "database snapshot $snapshot requested"

vault="$(tf_out backup_vault)"
bucket="arn:aws:s3:::three-tier-tfstate-$(aws sts get-caller-identity --query Account --output text)-$AWS_REGION"
job="$(aws backup start-backup-job --backup-vault-name "$vault" --resource-arn "$bucket" \
  --iam-role-arn "$(tf_out backup_role_arn)" --lifecycle DeleteAfterDays=7 --query BackupJobId --output text)"
log "state bucket backup job $job started"

start=$(date +%s); db_status=""; job_status=""
while [ $(( $(date +%s) - start )) -lt 2700 ]; do
  db_status="$(aws rds describe-db-snapshots --db-snapshot-identifier "$snapshot" --query 'DBSnapshots[0].Status' --output text 2>/dev/null || echo unknown)"
  job_status="$(aws backup describe-backup-job --backup-job-id "$job" --query State --output text 2>/dev/null || echo unknown)"
  if [ "$db_status" = available ] && { [ "$job_status" = COMPLETED ] || [ "$job_status" = FAILED ] || [ "$job_status" = ABORTED ]; }; then break; fi
  sleep 20
done
log "database snapshot: $db_status; state bucket backup: $job_status"
aws backup describe-backup-job --backup-job-id "$job" --query '{RecoveryPoint:RecoveryPointArn,Size:BackupSizeInBytes,Message:StatusMessage}' --output table
[ "$db_status" = available ] && [ "$job_status" = COMPLETED ]
