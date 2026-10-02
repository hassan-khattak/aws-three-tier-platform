# Infrastructure contract

Account facts and fixed inputs the Terraform configuration must use. Verification is in [readiness evidence](../evidence/readiness.md) and pricing in [the cost estimate](../costs.md).

| Input | Value |
| --- | --- |
| Region | `us-east-1` |
| Availability zones | `use1-az1`, `use1-az2` (by AZ ID; never `use1-az3`) |
| Fargate | on-demand only; 0.25 vCPU / 512 MiB per task; 2 web + 2 API tasks; account vCPU quota 6 |
| Database | RDS PostgreSQL `16.14`, `db.t4g.micro`, Multi-AZ, gp3 20 GB, encrypted, private; automatic minor upgrades off; planned upgrade target `16.15` |
| Database TLS | clients verify with the RDS global CA bundle shipped in the API image |
| Container images | `linux/amd64`, port 3000, read-only root filesystem, stop timeout ≥ 30 s; see [application contract](application.md) |
| Health checks | load balancer targets use `/health/live`; release verification uses `/health/ready` |

## Stack outputs (network)

| Output | Value |
| --- | --- |
| `aws_region` | `us-east-1` |
| `vpc_id` | `vpc-0123456789abcdef0` |
| `public_subnet_ids` | `subnet-069c68f33679c7a4c`, `subnet-0385a4c92ff1122e3` |
| `private_subnet_ids` | `subnet-08530d63e75c8b84e`, `subnet-0d20059b06aaf7d7f` |
| `availability_zone_ids` | `use1-az1`, `use1-az2` |
| `alb_security_group_id` | `sg-0793c743f2c3093ad` |
| `web_security_group_id` | `sg-0bfcbc7b50a175773` |
| `api_security_group_id` | `sg-02ce8543b2af53f8d` |
| `db_security_group_id` | `sg-0343462d76dfb124f` |
| `probe_security_group_id` | `sg-0b1fbf7ecc901b907` |

Allowed edges: ALB → web/API 3000; web, probe → ALB 80; API → DB 5432; web, API, probe → 0.0.0.0/0 443. CloudFront origin ingress to the ALB group is added with the CDN. Consumers read these with `terraform output` rather than copying IDs.

## Stack outputs (registries, identities, secret)

| Output | Value |
| --- | --- |
| `web_repository_url` | `123456789012.dkr.ecr.us-east-1.amazonaws.com/three-tier/web` |
| `api_repository_url` | `123456789012.dkr.ecr.us-east-1.amazonaws.com/three-tier/api` |
| `execution_role_arns` | `three-tier-{web,api,operator}-execution` (pull own image, write `/ecs/three-tier/<name>` logs; API and operator also read the DB secret) |
| `task_role_arns` | `three-tier-{web,api}-task` (no permissions) |
| `db_app_secret_arn` | `arn:aws:secretsmanager:us-east-1:123456789012:secret:three-tier/db/app-AbCdEf`; JSON `{"username","password"}`, populated with the DB role |

Operator tasks run the API image with the API security group and the operator execution role. Log groups must be named `/ecs/three-tier/{web,api,operator}` to match the roles.

## CI identities

| Role | Assumable by | Can |
| --- | --- | --- |
| `arn:aws:iam::123456789012:role/three-tier-ci-plan` | any branch of `example-org/submission-repo` | read-only account view; read stack state; take the stack lock |
| `arn:aws:iam::123456789012:role/three-tier-ci-release` | `main` only | push to both ECR repositories; register task definitions; update `three-tier` services; run/stop `three-tier-*` tasks; pass only the service execution/task roles to ECS |
| `arn:aws:iam::123456789012:role/three-tier-ci-infra` | `main` only | apply the stack (PowerUser + IAM limited to `three-tier-*`); cannot modify the bootstrap state or the bucket's protections |

Jobs request `id_tokens: { AWS_ID_TOKEN: { aud: sts.amazonaws.com } }` and call `aws sts assume-role-with-web-identity`. Credentials last at most one hour.
