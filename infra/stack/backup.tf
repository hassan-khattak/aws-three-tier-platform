# Daily backup of mutable storage outside the database. The database has RDS
# automated daily backups with point-in-time recovery (database.tf); the
# Terraform state bucket is versioned and, here, also backed up daily into a
# separate vault so a bucket-level loss is recoverable.
resource "aws_backup_vault" "main" {
  name = "${var.project}-backups"
  # Teardown must delete recovery points first (scripts/runtime/teardown.sh).
}

resource "aws_backup_plan" "daily" {
  name = "${var.project}-daily"

  rule {
    rule_name         = "daily"
    target_vault_name = aws_backup_vault.main.name
    schedule          = "cron(30 3 * * ? *)" # 03:30 UTC, after the RDS window
    start_window      = 60
    completion_window = 180

    lifecycle {
      delete_after = var.backup_retention_days
    }
  }
}

data "aws_iam_policy_document" "backup_trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["backup.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "backup" {
  name               = "${var.project}-backup"
  assume_role_policy = data.aws_iam_policy_document.backup_trust.json
}

resource "aws_iam_role_policy_attachment" "backup" {
  for_each = toset([
    "arn:aws:iam::aws:policy/AWSBackupServiceRolePolicyForS3Backup",
    "arn:aws:iam::aws:policy/AWSBackupServiceRolePolicyForS3Restore",
  ])
  role       = aws_iam_role.backup.name
  policy_arn = each.value
}

resource "aws_backup_selection" "state_bucket" {
  name         = "${var.project}-state-bucket"
  plan_id      = aws_backup_plan.daily.id
  iam_role_arn = aws_iam_role.backup.arn
  resources    = ["arn:aws:s3:::${local.state_bucket}"]
}
