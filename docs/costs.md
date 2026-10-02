# Deployment cost estimate

Expected AWS usage cost for the first seven deployed days in `us-east-1`, before credits and tax. Paid GitLab usage is excluded. Target: USD 50.

Unit prices come from the AWS Price List API (`aws pricing get-products --region us-east-1`), retrieved 2026-09-30. The CloudWatch dashboard price ($3.00 per dashboard-month) is the published rate and was not returned by the API. All arithmetic is in [scripts/cost/estimate.py](../scripts/cost/estimate.py); rerun it after changing a quantity.

## Sized deployment

| Resource | Size |
| --- | --- |
| Web and API | ECS Fargate, on-demand, Linux x86, 2 tasks each, 0.25 vCPU / 0.5 GB per task, one public IPv4 per task (no NAT gateway) |
| Load balancer | one internal Application Load Balancer |
| Database | RDS PostgreSQL 16.14, `db.t4g.micro`, Multi-AZ (one standby), 20 GB gp3; planned upgrade target 16.15 |
| Edge | CloudFront default hostname with a VPC origin to the internal ALB (VPC origins have no separate charge) |
| Other | Secrets Manager (2 secrets), CloudWatch Logs/alarms/dashboard, S3 for Terraform state and access logs, ECR for images, AWS-managed encryption keys |

The task size was checked locally: 200 page views at concurrency 20 with no failures and memory well below 0.5 GB (see [application evidence](evidence/application.md)).

## Seven-day estimate

| Item | Quantity x unit price (USD) | 7-day USD |
| --- | --- | ---: |
| Fargate vCPU (0.25 vCPU/task) | 697 task-h x 0.25 x 0.04048 | 7.05 |
| Fargate memory (0.5 GB/task) | 697 task-h x 0.5 x 0.004445 | 1.55 |
| Task public IPv4 | 697 h x 0.005 | 3.48 |
| Internal ALB hours | 168 h x 0.0225 | 3.78 |
| ALB capacity units (assume 1 LCU avg) | 168 LCU-h x 0.008 | 1.34 |
| RDS db.t4g.micro Multi-AZ | 168 h x 0.032 | 5.38 |
| RDS gp3 20 GB Multi-AZ | 20 GB x 0.23 x 168/730 | 1.06 |
| Temporary 2nd Multi-AZ DB (restore + upgrade) | 12 h x 0.032 + 20 GB x 0.23 x 12/730 | 0.46 |
| RDS backups (within free allocation = DB size) | 0 GB charged | 0.00 |
| Secrets Manager (app + RDS-managed master) | 2 x 0.4 x 168/730 | 0.18 |
| CloudWatch Logs ingest (assume 2 GB) | 2 GB x 0.5 | 1.00 |
| CloudWatch Logs storage | 2 GB x 0.03 x 168/730 | 0.01 |
| CloudWatch alarms (5) | 5 x 0.1 x 168/730 | 0.12 |
| CloudWatch dashboard (1; free tier covers 3) | 1 x 3.0 x 168/730, worst case | 0.69 |
| S3: state, ALB and CDN logs (assume 2 GB) | 2 GB x 0.023 x 168/730 | 0.01 |
| ECR images (assume 1 GB kept) | 1 GB x 0.1 x 168/730 | 0.02 |
| CloudFront (5 GB, 100k HTTPS; free tier 1 TB/10M) | 5 x 0.085 + 100000 x 0.000001, worst case | 0.53 |
| **Total (before credits and tax)** | | **26.67** |

Target 50.00; headroom 23.33 (53% of target)
Each extra hosted day (steady state): 3.46
Largest items: Fargate vCPU (0.25 vCPU/task) 7.05, RDS db.t4g.micro Multi-AZ 5.38, Internal ALB hours 3.78, Task public IPv4 3.48
Retained after teardown: state bucket + one final snapshot (~1 GB x 0.095) = 0.10/month

## Assumptions

- 168 hours of four baseline tasks; ten rolling releases, each running four extra tasks for 30 minutes; five hours of one-off operator tasks.
- One temporary Multi-AZ database for 12 hours in total, shared by the restore test and the upgrade rehearsal (counted once).
- About 1 load balancer capacity unit per hour on average, which is generous for this traffic.
- Backup storage stays within the free allocation (equal to provisioned storage) during the window.
- CloudFront, dashboard and log volumes are priced at paid rates as a worst case; the always-free tier (1 TB and 10 million requests per month for CloudFront, 3 dashboards) would normally cover them.

## Approved hosting window and credits

Hosting runs until the end of Monday 2026-10-05 (at most about 108 hours if deployment starts on 2026-10-01): `python3 scripts/cost/estimate.py 108` gives **USD 18.01**. The account has **USD 100.00** in credits (Billing → Credits, 2026-10-01, none used), which covers this window several times over. Tax and credit eligibility of individual services are not verified.

## After the window

Keeping the deployment running costs about USD 3.46 per extra day at steady state. After teardown, the Terraform state bucket and one final database snapshot remain, at about USD 0.10 per month. The deployment owner deletes the whole deployment after the interview; the backend bucket is removed last.

## Not included

Credits (none recorded yet), tax, GitLab compute beyond its free allowance, traffic far above the assumptions, and any extra environment.
