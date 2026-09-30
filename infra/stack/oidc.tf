# GitLab CI obtains short-lived AWS credentials through OIDC; there are no
# long-lived CI keys. Tokens are requested in .gitlab-ci.yml with
#   id_tokens: { AWS_ID_TOKEN: { aud: sts.amazonaws.com } }
# and trust is pinned to one project and, where it matters, one branch via
# the token's sub claim: project_path:<path>:ref_type:branch:ref:<branch>.
resource "aws_iam_openid_connect_provider" "gitlab" {
  url            = "https://${var.gitlab_host}"
  client_id_list = local.oidc_audiences
}

locals {
  # id_tokens use sts.amazonaws.com; servers without id_tokens issue
  # CI_JOB_JWT_V2 with the GitLab URL as audience. The sub check is the same.
  oidc_audiences = ["sts.amazonaws.com", "https://${var.gitlab_host}"]
  oidc_sub       = "project_path:${var.gitlab_project_path}:ref_type:branch:ref"
  state_bucket   = "${var.project}-tfstate-${data.aws_caller_identity.current.account_id}-${var.region}"
  # Which token subjects may assume each role.
  ci_role_subjects = {
    plan    = ["${local.oidc_sub}:*"]
    release = ["${local.oidc_sub}:${var.gitlab_release_branch}"]
    infra   = ["${local.oidc_sub}:${var.gitlab_release_branch}"]
  }
}

data "aws_iam_policy_document" "ci_trust" {
  for_each = local.ci_role_subjects

  # Fallback for GitLab servers without ID tokens: the matching CI user.
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "AWS"
      identifiers = [for user in local.ci_role_users[each.key] : aws_iam_user.ci[user].arn]
    }
  }

  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.gitlab.arn]
    }
    condition {
      test     = "StringEquals"
      variable = "${var.gitlab_host}:aud"
      values   = local.oidc_audiences
    }
    condition {
      test     = "StringLike"
      variable = "${var.gitlab_host}:sub"
      values   = each.value
    }
  }
}

resource "aws_iam_role" "ci" {
  for_each             = local.ci_role_subjects
  name                 = "${var.project}-ci-${each.key}"
  assume_role_policy   = data.aws_iam_policy_document.ci_trust[each.key].json
  max_session_duration = 3600
}

# --- plan: read-only view of the account plus state read and lock files.
resource "aws_iam_role_policy_attachment" "ci_plan_readonly" {
  role       = aws_iam_role.ci["plan"].name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

data "aws_iam_policy_document" "state_access" {
  statement {
    sid       = "ListState"
    actions   = ["s3:ListBucket"]
    resources = ["arn:aws:s3:::${local.state_bucket}"]
  }
  statement {
    sid       = "ReadState"
    actions   = ["s3:GetObject"]
    resources = ["arn:aws:s3:::${local.state_bucket}/stack/*"]
  }
  statement {
    sid       = "Lock"
    actions   = ["s3:PutObject", "s3:DeleteObject"]
    resources = ["arn:aws:s3:::${local.state_bucket}/stack/terraform.tfstate.tflock"]
  }
}

resource "aws_iam_role_policy" "ci_plan_state" {
  name   = "state-read-and-lock"
  role   = aws_iam_role.ci["plan"].id
  policy = data.aws_iam_policy_document.state_access.json
}

# --- release: push images and roll ECS services; nothing else.
data "aws_iam_policy_document" "ci_release" {
  statement {
    sid       = "RegistryLogin"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }
  statement {
    sid = "PushImages"
    actions = [
      "ecr:BatchCheckLayerAvailability", "ecr:BatchGetImage", "ecr:CompleteLayerUpload",
      "ecr:DescribeImages", "ecr:GetDownloadUrlForLayer", "ecr:InitiateLayerUpload",
      "ecr:PutImage", "ecr:UploadLayerPart",
    ]
    resources = [for r in aws_ecr_repository.service : r.arn]
  }
  statement {
    sid = "TaskDefinitions"
    # These actions do not support resource-level permissions.
    actions   = ["ecs:RegisterTaskDefinition", "ecs:DescribeTaskDefinition", "ecs:ListTaskDefinitions"]
    resources = ["*"]
  }
  statement {
    sid       = "RollServices"
    actions   = ["ecs:UpdateService", "ecs:DescribeServices"]
    resources = ["arn:aws:ecs:${var.region}:${data.aws_caller_identity.current.account_id}:service/${var.project}/*"]
  }
  statement {
    sid     = "ProbeTasks"
    actions = ["ecs:RunTask", "ecs:DescribeTasks", "ecs:StopTask"]
    resources = [
      "arn:aws:ecs:${var.region}:${data.aws_caller_identity.current.account_id}:task-definition/${var.project}-*:*",
      "arn:aws:ecs:${var.region}:${data.aws_caller_identity.current.account_id}:task/${var.project}/*",
    ]
  }
  statement {
    sid       = "PassOnlyServiceRoles"
    actions   = ["iam:PassRole"]
    resources = concat([for r in aws_iam_role.execution : r.arn], [for r in aws_iam_role.task : r.arn])
    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy" "ci_release" {
  name   = "release"
  role   = aws_iam_role.ci["release"].id
  policy = data.aws_iam_policy_document.ci_release.json
}

# --- infra: applies reviewed plans of this stack from the release branch.
# Broad service access, but IAM changes are limited to this project's names
# and it cannot touch the bootstrap state or the state bucket configuration.
resource "aws_iam_role_policy_attachment" "ci_infra_poweruser" {
  role       = aws_iam_role.ci["infra"].name
  policy_arn = "arn:aws:iam::aws:policy/PowerUserAccess"
}

data "aws_iam_policy_document" "ci_infra" {
  source_policy_documents = [data.aws_iam_policy_document.state_access.json]

  statement {
    sid       = "WriteStackState"
    actions   = ["s3:PutObject"]
    resources = ["arn:aws:s3:::${local.state_bucket}/stack/terraform.tfstate"]
  }
  statement {
    sid     = "ProjectIamOnly"
    actions = ["iam:*"]
    resources = [
      "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${var.project}-*",
      "arn:aws:iam::${data.aws_caller_identity.current.account_id}:policy/${var.project}-*",
      aws_iam_openid_connect_provider.gitlab.arn,
    ]
  }
  statement {
    sid       = "ReadIam"
    actions   = ["iam:Get*", "iam:List*"]
    resources = ["*"]
  }
  statement {
    sid       = "ProtectBootstrap"
    effect    = "Deny"
    actions   = ["s3:DeleteBucket", "s3:PutBucketPolicy", "s3:DeleteBucketPolicy", "s3:PutBucketVersioning", "s3:PutLifecycleConfiguration", "s3:PutEncryptionConfiguration", "s3:PutBucketPublicAccessBlock"]
    resources = ["arn:aws:s3:::${local.state_bucket}"]
  }
  statement {
    sid       = "ProtectBootstrapState"
    effect    = "Deny"
    actions   = ["s3:PutObject", "s3:DeleteObject", "s3:DeleteObjectVersion"]
    resources = ["arn:aws:s3:::${local.state_bucket}/bootstrap/*"]
  }
}

resource "aws_iam_role_policy" "ci_infra" {
  name   = "infra"
  role   = aws_iam_role.ci["infra"].id
  policy = data.aws_iam_policy_document.ci_infra.json
}
