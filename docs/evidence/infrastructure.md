# Infrastructure verification

Account `123456789012`, `us-east-1`. Terraform 1.16.4, AWS provider 6.67.x (locked in `.terraform.lock.hcl`). The provider schema includes `aws_cloudfront_vpc_origin`.

## State backend — 2026-10-01

| Check | Result |
| --- | --- |
| `terraform fmt -check -recursive infra`, `validate` both roots | pass |
| Bootstrap apply (local state) | 7 added: bucket `three-tier-tfstate-123456789012-us-east-1`, ownership controls, public access block, versioning, SSE-S3, lifecycle (noncurrent 90 d, abort multipart 7 d), policy (deny non-TLS, deny other accounts) |
| Migration | `init -migrate-state` to `bootstrap/terraform.tfstate`; remote state resources and outputs equal to the local copy; local copy deleted; plan: no changes |
| Main stack backend | `stack/terraform.tfstate`, `use_lockfile = true` |
| Lock contention | session 1 held the lock at an apply prompt (`bootstrap/terraform.tfstate.tflock` present); session 2 `plan -lock-timeout=5s` failed after 7 s with "Error acquiring the state lock" naming the holder; session 1 cancelled; lock released; plan: no changes |
| Previous-version retrieval | after the registry/IAM apply the stack key had 2 versions; the previous one (serial 1, 25 resources, no ECR) was fetched into a mode-700 temp dir; live version (serial 2, 34 resources, same lineage) unchanged (same ETag); plan afterwards: no changes; temp dir deleted |

## Network — 2026-10-01

Plan 32 to add, 0 change, 0 destroy; applied; repeat plan: no changes.

| Check (AWS API, independent of Terraform) | Result |
| --- | --- |
| VPC | `vpc-0123456789abcdef0`, `10.42.0.0/16` |
| Subnets | public `10.42.0.0/24` use1-az1, `10.42.1.0/24` use1-az2; private `10.42.10.0/24` use1-az1, `10.42.11.0/24` use1-az2; none auto-assign public IPs |
| Routes | public table: local + `0.0.0.0/0` → IGW; private table and main table: local only |
| NAT gateways | 0 |
| Security group rules | 13 total; 0 inbound rules from any CIDR; default group has 0 rules |

Reachability is not proven by inspection; it is tested once the load balancer, tasks and database exist.

## Registries, identities and secret — 2026-10-01

Plan 13 to add; applied; repeat plan: no changes.

| Check | Result |
| --- | --- |
| ECR | `three-tier/web`, `three-tier/api`: IMMUTABLE tags, scan on push, AES256; lifecycle keeps the newest 20 images |
| Secret | `three-tier/db/app` created with no value (0 versions); ARN output only |
| IAM simulation (`simulate-principal-policy`) | web execution: DB secret implicitDeny, own image allowed, API image implicitDeny. API execution: DB secret allowed, web image implicitDeny, `ecr:PutImage` implicitDeny. Operator execution: DB secret allowed. Web and API task roles: DB secret implicitDeny, unrelated S3 call implicitDeny |
| GitLab OIDC | see below |
| Budget | skipped by decision (USD 100 credits; no alarm for now) |

## GitLab CI identities — 2026-10-01

CI runs in the submission repository `gitlab.example.com/example-org/submission-repo` (default branch `main`).

| Check | Result |
| --- | --- |
| Issuer discovery | `https://gitlab.example.com/.well-known/openid-configuration` public; issuer `https://gitlab.example.com`; JWKS `https://gitlab.example.com/oauth/discovery/keys` HTTP 200; RS256; publicly trusted certificate |
| Provider | `arn:aws:iam::123456789012:oidc-provider/gitlab.example.com`, audience `sts.amazonaws.com` |
| Trust (as stored by IAM) | all roles require `aud = sts.amazonaws.com`. `three-tier-ci-plan`: `sub` like `project_path:example-org/submission-repo:ref_type:branch:ref:*`. `three-tier-ci-release` and `three-tier-ci-infra`: `sub` = `…:ref:main` |
| Apply | 9 added; repeat plan: no changes |
| Permission simulation | 17/17 as expected. Release: push to `three-tier/api` allowed, update `service/three-tier/api` allowed, pass API execution role to `ecs-tasks` allowed but to another service denied, pass CI roles denied, create roles denied, read state denied, read DB secret denied. Plan: read stack state and write its lock file allowed, write state denied, create resources denied, read DB secret denied. Infra: write stack state allowed, write bootstrap state and delete bucket explicitly denied, IAM changes only on `three-tier-*` names |
| Real token exchange | **pending**: needs a pipeline job on a runner (checked when CI is added) |

## CI login on gitlab.example.com — 2026-10-01

Working project `example-user/three-tier` (owner access, own runner). Submission repository receives no pipelines.

| Check | Result |
| --- | --- |
| Server / runner | GitLab 17.8.7; runner first 19.4.1, then 17.8.5 (major.minor matched per GitLab docs) |
| `id_tokens` (`aud: sts.amazonaws.com` and `aud: https://gitlab.example.com`) | empty with both runners; no ID-token variables present at all; `CI_JOB_JWT*` absent (removed in GitLab 17.0) |
| Conclusion | the server issues no CI ID tokens (instance-level; not changeable by the candidate). OIDC trust kept but unused |
| Fallback | IAM users `ci/three-tier-ci-plan` (may only assume the plan role) and `ci/three-tier-ci-deploy` (only release and infra); 8/8 simulations as expected; keys created in the console and stored as masked GitLab variables (deploy keys protected) |
| Key exposure | both CI user keys were pasted into the assistant conversation on 2026-10-01; the owner chose not to rotate. Keys must be deleted at teardown (by 2026-10-05) |
| First CI login | 2026-10-01, pipeline 41742 job 162517 on runner 17.8.5: assumed `three-tier-ci-plan` via CI user key; `create-vpc --dry-run` refused with UnauthorizedOperation; job succeeded. DEPLOY_* variables were still visible to an unprotected branch at that time (protection pending) |
