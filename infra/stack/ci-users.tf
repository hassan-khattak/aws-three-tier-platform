# Fallback CI login for GitLab servers that issue no ID tokens (the working
# GitLab 17.8.7 instance issues none). Each user can only assume its matching
# scoped role(s); jobs then run on 1-hour role sessions. Access keys are
# created by the operator in the console and stored directly as masked GitLab
# CI/CD variables, so they never enter Terraform state or logs:
#   plan   -> PLAN_AWS_ACCESS_KEY_ID / PLAN_AWS_SECRET_ACCESS_KEY (all branches)
#   deploy -> DEPLOY_AWS_ACCESS_KEY_ID / DEPLOY_AWS_SECRET_ACCESS_KEY (protected)
locals {
  ci_users = {
    plan   = ["plan"]
    deploy = ["release", "infra"]
  }
  # Inverse map: role -> users allowed to assume it.
  ci_role_users = { for role in keys(local.ci_role_subjects) : role => [for user, roles in local.ci_users : user if contains(roles, role)] }
}

resource "aws_iam_user" "ci" {
  for_each = local.ci_users
  name     = "${var.project}-ci-${each.key}"
  path     = "/ci/"

  # The console tags users with access-key descriptions when keys are created.
  lifecycle {
    ignore_changes = [tags]
  }
}

data "aws_iam_policy_document" "ci_user" {
  for_each = local.ci_users
  statement {
    actions   = ["sts:AssumeRole"]
    resources = [for role in each.value : "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${var.project}-ci-${role}"]
  }
}

resource "aws_iam_user_policy" "ci" {
  for_each = local.ci_users
  name     = "assume-scoped-ci-roles"
  user     = aws_iam_user.ci[each.key].name
  policy   = data.aws_iam_policy_document.ci_user[each.key].json
}
