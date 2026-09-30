# Source in a CI job:  . scripts/ci/aws-login.sh <plan|release|infra>
# Exports short-lived credentials for the scoped CI role and nothing else.
#  - With a GitLab ID token (AWS_ID_TOKEN), uses OIDC web identity.
#  - Otherwise (servers that issue no ID tokens) assumes the role with the
#    matching CI user's key: PLAN_* for plan, DEPLOY_* (protected) for
#    release/infra. The long-lived keys are removed from the environment after.
# Prints only the assumed role identity; never key material.
# POSIX sh: runs in the AWS CLI (bash), Docker (ash) and Terraform images.

_aws_login() {
  _role="$1"; _account="${AWS_ACCOUNT_ID:-123456789012}"
  case "$_role" in
    plan) _prefix=PLAN ;;
    release|infra) _prefix=DEPLOY ;;
    *) echo "aws-login: role must be plan, release or infra" >&2; return 2 ;;
  esac
  _arn="arn:aws:iam::${_account}:role/three-tier-ci-${_role}"
  _session="gitlab-${CI_PIPELINE_ID:-local}-${CI_JOB_ID:-0}"
  unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN

  if [ -n "${AWS_ID_TOKEN:-}" ]; then
    _creds="$(aws sts assume-role-with-web-identity --role-arn "$_arn" --role-session-name "$_session" \
      --web-identity-token "$AWS_ID_TOKEN" --duration-seconds 3600 \
      --query 'Credentials.[AccessKeyId,SecretAccessKey,SessionToken]' --output text)" || return 1
    echo "aws-login: OIDC web identity"
  else
    eval "_key_id=\${${_prefix}_AWS_ACCESS_KEY_ID:-}"
    eval "_secret=\${${_prefix}_AWS_SECRET_ACCESS_KEY:-}"
    if [ -z "$_key_id" ] || [ -z "$_secret" ]; then
      if [ "$_prefix" = PLAN ]; then
        echo "aws-login: no ID token and PLAN_AWS_ACCESS_KEY_ID/PLAN_AWS_SECRET_ACCESS_KEY not set for this job." \
             "Add them as masked, NOT protected CI/CD variables with environment scope All." >&2
      else
        echo "aws-login: no ID token and DEPLOY_AWS_ACCESS_KEY_ID/DEPLOY_AWS_SECRET_ACCESS_KEY not available." \
             "They are protected variables: release/infra jobs only get them on protected branches (main)." >&2
      fi
      return 1
    fi
    _creds="$(AWS_ACCESS_KEY_ID="$_key_id" AWS_SECRET_ACCESS_KEY="$_secret" \
      aws sts assume-role --role-arn "$_arn" --role-session-name "$_session" --duration-seconds 3600 \
      --query 'Credentials.[AccessKeyId,SecretAccessKey,SessionToken]' --output text)" || return 1
    echo "aws-login: CI user key (no ID token issued by this server)"
  fi
  unset PLAN_AWS_ACCESS_KEY_ID PLAN_AWS_SECRET_ACCESS_KEY DEPLOY_AWS_ACCESS_KEY_ID DEPLOY_AWS_SECRET_ACCESS_KEY _key_id _secret
  # Output is three tab-separated fields.
  set -- $_creds
  export AWS_ACCESS_KEY_ID="$1" AWS_SECRET_ACCESS_KEY="$2" AWS_SESSION_TOKEN="$3"
  unset _creds
  aws sts get-caller-identity --query Arn --output text
}
_aws_login "$@"
