locals {
  services = ["web", "api"]
  # Log groups are created with the services; roles are scoped to their names.
  log_group_arn = { for s in concat(local.services, ["operator"]) : s =>
  "arn:aws:logs:${var.region}:${data.aws_caller_identity.current.account_id}:log-group:/ecs/${var.project}/${s}" }
}

data "aws_caller_identity" "current" {}

data "aws_iam_policy_document" "ecs_tasks_trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }
}

# Execution roles: used by ECS itself to pull the image, write logs and, for
# the API only, inject the database secret at container start.
resource "aws_iam_role" "execution" {
  for_each           = toset(concat(local.services, ["operator"]))
  name               = "${var.project}-${each.key}-execution"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_trust.json
}

data "aws_iam_policy_document" "execution" {
  for_each = aws_iam_role.execution

  statement {
    sid       = "RegistryLogin"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    sid     = "PullOwnImage"
    actions = ["ecr:BatchCheckLayerAvailability", "ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer"]
    # One-off operator tasks run the API image (it contains the DB client and CA).
    resources = [aws_ecr_repository.service[each.key == "operator" ? "api" : each.key].arn]
  }

  statement {
    sid       = "WriteOwnLogs"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${local.log_group_arn[each.key]}:log-stream:*"]
  }

  dynamic "statement" {
    for_each = each.key == "web" ? [] : [1]
    content {
      sid       = "ReadDatabaseSecret"
      actions   = ["secretsmanager:GetSecretValue"]
      resources = [aws_secretsmanager_secret.db_app.arn]
    }
  }

  # Only the operator may read the RDS-managed master credential.
  dynamic "statement" {
    for_each = each.key == "operator" ? [1] : []
    content {
      sid       = "ReadMasterSecret"
      actions   = ["secretsmanager:GetSecretValue"]
      resources = [for db in aws_db_instance.generation : db.master_user_secret[0].secret_arn]
    }
  }
}

resource "aws_iam_role_policy" "execution" {
  for_each = aws_iam_role.execution
  name     = "execution"
  role     = each.value.id
  policy   = data.aws_iam_policy_document.execution[each.key].json
}

# Task roles: the identity of the running application. Neither service calls
# AWS APIs, so they have no permissions.
resource "aws_iam_role" "task" {
  for_each           = toset(local.services)
  name               = "${var.project}-${each.key}-task"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_trust.json
}
