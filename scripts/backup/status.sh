#!/usr/bin/env bash
# Reports database backup configuration and actual backup state. It never
# reports a scheduled backup as successful before one has run.
#
# Usage: scripts/backup/status.sh [generation]    (default: active generation)
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export AWS_REGION="${AWS_REGION:-us-east-1}"
generation="${1:-$(terraform -chdir="$root/infra/stack" output -raw active_db_generation)}"
db="$(terraform -chdir="$root/infra/stack" output -json db_generations | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{const g=JSON.parse(s)[process.argv[1]];if(!g){console.error("unknown generation");process.exit(2)}console.log(g.identifier)})' "$generation")"

aws rds describe-db-instances --db-instance-identifier "$db" --query 'DBInstances[0].{Instance:DBInstanceIdentifier,Status:DBInstanceStatus,MultiAZ:MultiAZ,Encrypted:StorageEncrypted,RetentionDays:BackupRetentionPeriod,BackupWindowUTC:PreferredBackupWindow,LatestRestorableTime:LatestRestorableTime,DeletionProtection:DeletionProtection}' --output table

snapshots="$(aws rds describe-db-snapshots --db-instance-identifier "$db" --snapshot-type automated \
  --query 'reverse(sort_by(DBSnapshots,&SnapshotCreateTime))[].[SnapshotCreateTime,Status]' --output text)"
if [ -z "$snapshots" ]; then
  echo "Automated snapshots: none yet. The first daily backup has not run; recovery relies on point-in-time logs once LatestRestorableTime is set."
else
  echo "Automated snapshots (newest first):"; printf '%s\n' "$snapshots" | head -7
  newest="$(printf '%s\n' "$snapshots" | head -1 | cut -f1)"
  node -e 'const h=(Date.now()-Date.parse(process.argv[1]))/36e5; console.log(`Newest automated snapshot age: ${h.toFixed(1)} h` + (h > 26 ? " (STALE: older than one daily cycle)" : ""))' "$newest"
fi
