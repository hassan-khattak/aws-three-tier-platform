# Delivery plan: three-tier Node application on AWS

**Author:** Hassan Khattak · **Started:** 2026-09-30 · **Status as of 2026-10-02:** deployed and verified; see [Status](#status).

This is the plan I worked from: what was asked, how I interpreted it, the decisions taken and why, the order of delivery, and how each part was proven. The operational details live in the [README](README.md) and [architecture notes](docs/architecture.md).

## 1. Problem

Deliver the supplied web → API → PostgreSQL application as a continuously delivered, scalable and secure system on one major cloud, with infrastructure as code, failure tolerance, zero-downtime updates, daily backups, central logs, historical metrics and a CDN. This repository holds everything except the CI service itself.

## 2. Requirements and interpretation

| # | Requirement | Interpretation used for acceptance |
| --- | --- | --- |
| R1 | Fork and use the supplied repository | Preserve the original history; no rewrite of the application beyond fixes needed for production |
| R2 | Web and API reachable from the internet; database not | One public entry (CDN); DB only reachable from API tasks |
| R3 | Entire architecture as code | Terraform for every resource, including the state backend; repeat plans must be clean |
| R4 | Survive server (instance) failures | Losing a task must not drop requests; losing the DB primary must recover automatically |
| R5 | Update components without downtime | Rolling application releases and a database engine update, measured under traffic |
| R6 | Fully automated deployment of new code | Merge to the default branch → test → build → release, with no manual step |
| R7 | (Bonus) tests in the pipeline | Unit tests of both services gate the release |
| R8 | Daily backups of the DB and mutable storage | Scheduled backups observed, plus a proven restore |
| R9 | Logs of all tiers easily accessible, not on hosts | Central, searchable, with request correlation |
| R10 | One major cloud | AWS |
| R11 | Historical metrics to find bottlenecks | One dashboard across tiers, plus alarms |
| R12 | CDN for location-based delivery | Edge caching of static content; dynamic content never cached |
| R13 | All artifacts in version control | Code, IaC, scripts, CI configuration, diagram |
| R14 | Working deployment before the interview | Kept running through the interview; submitted at least 6 hours earlier |

## 3. Constraints and assumptions

- **Time:** seven days from receipt, so scope stays at what the requirements justify. No UI work, no extra environments, no new data features.
- **Cost:** a short-lived deployment. Target under USD 50 for seven days; estimated at about USD 3.50 per day.
- **Application:** read-only. It runs `SELECT now()` and nothing else. This makes a parallel-database upgrade safe, and the plan depends on it.
- **CI host:** CI runs on GitHub Actions hosted runners in the same repository as the code.

## 4. Architecture decisions

| Decision | Choice | Alternatives considered | Why |
| --- | --- | --- | --- |
| Cloud | AWS, `us-east-1`, two AZs | GCP, Azure | Familiarity; mature managed services for each tier |
| IaC | Terraform, state in versioned, encrypted S3 with native locking | CloudFormation, CDK; DynamoDB locking | Portable and reviewable; native S3 locking removes a separate lock table |
| Compute | ECS Fargate, separate web and API services, 2 tasks each across 2 AZs | EC2 Auto Scaling, EKS, Lambda | No servers to patch; per-service scaling and rolling updates; EKS is heavier than this app needs |
| Database | RDS PostgreSQL Multi-AZ, private, encrypted, TLS required | Aurora, self-managed | Managed failover and backups at the lowest suitable cost |
| Entry and CDN | CloudFront → VPC origin → **internal** ALB | Public ALB behind CloudFront; S3 for assets | A single public entry; the load balancer is never internet-facing; no custom domain needed |
| Network egress | Tasks in public subnets with public IPv4 for outbound only, no inbound | NAT gateway, VPC endpoints | Lower cost; security groups allow inbound only from the ALB |
| Secrets | Secrets Manager; RDS-managed master; read-only app login | Environment files, SSM parameters | No secrets in Git, images or Terraform inputs |
| Releases | Rolling, healthy-before-drain, circuit breaker, public smoke test, automatic rollback | Blue/green with CodeDeploy | Built into ECS; enough for a stateless service |
| DB engine update | Restore a new generation, upgrade it, roll the API across, retire the old one | In-place upgrade; RDS Blue/Green | An in-place upgrade restarts the DB; Blue/Green still has a switchover interruption; the read-only app allows two generations to coexist |
| CI | GitHub Actions with OIDC to scoped IAM roles | GitLab CI, CodePipeline | Source and CI live in one place, hosted runners need no setup, and GitHub issues OIDC ID tokens, so no long-lived AWS keys are needed |
| Observability | CloudWatch Logs, metrics, dashboard and alarms; ALB logs in S3; CloudFront logs | Prometheus/Grafana, ELK | Native, no extra servers; enough to find bottlenecks |

## 5. Delivery phases

Each phase ended with its checks run and the results recorded before the next began.

| Phase | Outcome | Exit criteria |
| --- | --- | --- |
| 0. Readiness | Account, region, quotas, versions and cost confirmed | Account checks pass; cost within target |
| 1. Application readiness | Reproducible builds; bounded DB access; health, startup and shutdown behaviour; production images | 53 unit tests and PostgreSQL/TLS integration tests pass; images hardened |
| 2. Foundation | State backend, network, IAM, registries, secrets, CI identities | Locking and restore of state proven; no inbound internet paths |
| 3. Resilient tiers | Database, internal ALB, services, logs, runtime scripts | Private end-to-end probe passes; task-loss and DB failover measured |
| 4. CDN | CloudFront with VPC origin; cache rules; asset refresh | Static `Hit`, dynamic never cached, errors never cached |
| 5. Delivery | Pipeline: tests, plan, build, serialized release, rollback | A merge deploys new code with no manual step |
| 6. Backup and recovery | Daily DB backups, state versioning and backup, restore drill | Scheduled backup observed; isolated restore verified |
| 7. Observability | Dashboard, alarms, saved log queries | An alarm detected a real (tested) incident |
| 8. Hand-over | Engine upgrade rehearsal, documentation, submission | Upgrade measured under traffic; docs match the live system |

## 6. Verification strategy

- **Measure, don't assert.** A sampler inside the VPC requested `/` and `/api/status` every 500 ms during each failure and update test. The results recorded are counts of failed requests, not assumptions.
- **Test both sides.** Each security boundary was checked both ways: allowed paths work, and blocked paths fail, including from the internet.
- **Clean plans.** After every infrastructure change, a repeat Terraform plan had to show no changes.
- **Drills with cleanup.** The restore and upgrade exercises used temporary resources that were removed or retired afterwards.

## 7. Risks and how they were handled

| Risk | Mitigation |
| --- | --- |
| DB failover interrupts requests | Requests are bounded to 3 s (API) and 5 s (web) and fail fast with 503; the pool reconnects; liveness never depends on the DB. Measured: about 17 s of 503s, then automatic recovery |
| A bad release takes the site down | Healthy-before-drain rollout, ECS circuit breaker, public smoke test, automatic rollback |
| Engine upgrade downtime | Parallel database generation; the API is moved by a rolling configuration release. Measured: 0 failed requests |
| CI availability and network | Retries for transient failures (provider download), no dependence on job artifacts, all checks gate the release |
| Credential exposure | Least-privilege roles; keys restricted to role assumption; protected variables for deploy keys; rotation before submission |
| Cost overrun | Small task and DB sizes, no NAT gateway; teardown script after the interview |

## 8. Known limitations

- An unplanned DB failover still causes about 17 s of fast errors.
- No custom domain, so the default CloudFront certificate's TLS minimum applies.
- Fixed capacity of 2 + 2 tasks with scripted scaling, not autoscaling.
- Capacity was measured locally at the deployed task size, not load-tested on Fargate.

## 9. How AI assistance was used

I used an AI assistant (Claude) as a pair engineer: to lay out options and trade-offs, draft code, tests, Terraform and documentation, and run commands I asked for. Architecture choices, risk acceptance and scope were mine. I kept credentials out of the code and applied least privilege to every identity. Nothing is presented here as working unless it was run against the live system, and limitations are stated where a test was not possible. The original planning prompt and the detailed working notes are kept outside the submission.

## Status

All phases are delivered. The live system, test results and operating instructions are in the [README](README.md). Remaining before the interview: the first pipeline-driven release after the final merge, rotating the CI credentials used during setup, and the final submission.
