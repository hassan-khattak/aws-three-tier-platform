#!/usr/bin/env bash
# Removes the whole deployment after the assessment, in a safe order:
#   1. any leftover restore-drill database
#   2. the CI users' console-created access keys (IAM users with keys cannot
#      be deleted, and the keys must not outlive the deployment)
#   3. AWS Backup recovery points in the stack's vault (a vault with recovery
#      points cannot be deleted)
#   4. deletion protection off, ECR force-delete on (one targeted apply)
#   5. terraform destroy of infra/stack; RDS takes a final snapshot
#      named <project>-<generation>-final first
# The Terraform state bucket and bootstrap state are kept; remove them last,
# by hand, as described in the operations notes.
#
# Usage: scripts/runtime/teardown.sh --confirm-destroy
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export AWS_REGION="${AWS_REGION:-us-east-1}"
[ "${1:-}" = "--confirm-destroy" ] || { echo "Refusing: this deletes the deployment. Rerun with --confirm-destroy." >&2; exit 2; }
stack="$root/infra/stack"
log() { echo "$(date -u +%H:%M:%SZ) $*"; }

if aws rds describe-db-instances --db-instance-identifier three-tier-restore-drill >/dev/null 2>&1; then
  aws rds delete-db-instance --db-instance-identifier three-tier-restore-drill --skip-final-snapshot --delete-automated-backups >/dev/null
  log "restore-drill database deletion requested"
fi

for user in $(terraform -chdir="$stack" output -json ci_user_names | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>console.log(Object.values(JSON.parse(s)).join(" ")))'); do
  for key in $(aws iam list-access-keys --user-name "$user" --query 'AccessKeyMetadata[].AccessKeyId' --output text); do
    aws iam delete-access-key --user-name "$user" --access-key-id "$key"
    log "deleted access key ${key:0:4}…${key: -4} of $user"
  done
done

vault="$(terraform -chdir="$stack" output -raw backup_vault 2>/dev/null || true)"
if [ -n "$vault" ]; then
  for rp in $(aws backup list-recovery-points-by-backup-vault --backup-vault-name "$vault" --query 'RecoveryPoints[].RecoveryPointArn' --output text); do
    aws backup delete-recovery-point --backup-vault-name "$vault" --recovery-point-arn "$rp"
    log "deleted recovery point ${rp##*:}"
  done
fi

log "disabling deletion protection and allowing repository deletion"
terraform -chdir="$stack" apply -input=false -auto-approve \
  -var db_deletion_protection=false -var ecr_force_delete=true \
  -target=aws_db_instance.generation -target=aws_ecr_repository.service

log "destroying the stack (final DB snapshot is taken first)"
terraform -chdir="$stack" destroy -input=false -auto-approve \
  -var db_deletion_protection=false -var ecr_force_delete=true

log "remaining final snapshots:"
aws rds describe-db-snapshots --snapshot-type manual --query "DBSnapshots[?starts_with(DBSnapshotIdentifier,'three-tier-')].[DBSnapshotIdentifier,SnapshotCreateTime]" --output text
log "done. Kept: state bucket (infra/bootstrap) and final snapshots; delete them when no longer needed."
