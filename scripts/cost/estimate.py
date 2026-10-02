# All arithmetic for the deployment estimate. Unit prices: AWS Price List API,
# us-east-1, retrieved 2026-09-30 (dashboard: published price, not in API).
import sys
H = float(sys.argv[1]) if len(sys.argv) > 1 else 168   # hosted hours (default: seven days)
MONTH = 730        # hours per month for GB-Mo / per-month items
frac = H / MONTH
P = dict(vcpu=0.04048, gb=0.004445, ipv4=0.005, alb=0.0225, lcu=0.008,
         rds_maz=0.032, gp3_maz=0.23, backup=0.095, secret=0.40,
         logs_in=0.50, logs_store=0.03, alarm=0.10, dashboard=3.00,
         s3=0.023, ecr=0.10, cf_gb=0.085, cf_req=0.01/10000)
task_h = 4 * H                    # 2 web + 2 API tasks, whole window
surge_h = 10 * 4 * 0.5            # 10 rolling releases, 4 extra tasks, 30 min each
ops_h = 5                         # one-off operator/probe tasks
all_task_h = task_h + surge_h + ops_h
overlap_h = 12                    # one temporary Multi-AZ DB for restore + upgrade rehearsal
rows = [
  ("Fargate vCPU (0.25 vCPU/task)", f"{all_task_h:g} task-h x 0.25 x {P['vcpu']}", all_task_h*0.25*P['vcpu']),
  ("Fargate memory (0.5 GB/task)", f"{all_task_h:g} task-h x 0.5 x {P['gb']}", all_task_h*0.5*P['gb']),
  ("Task public IPv4", f"{all_task_h:g} h x {P['ipv4']}", all_task_h*P['ipv4']),
  ("Internal ALB hours", f"{H} h x {P['alb']}", H*P['alb']),
  ("ALB capacity units (assume 1 LCU avg)", f"{H} LCU-h x {P['lcu']}", H*P['lcu']),
  ("RDS db.t4g.micro Multi-AZ", f"{H} h x {P['rds_maz']}", H*P['rds_maz']),
  ("RDS gp3 20 GB Multi-AZ", f"20 GB x {P['gp3_maz']} x {H}/{MONTH}", 20*P['gp3_maz']*frac),
  ("Temporary 2nd Multi-AZ DB (restore + upgrade)", f"{overlap_h} h x {P['rds_maz']} + 20 GB x {P['gp3_maz']} x {overlap_h}/{MONTH}", overlap_h*P['rds_maz'] + 20*P['gp3_maz']*overlap_h/MONTH),
  ("RDS backups (within free allocation = DB size)", "0 GB charged", 0.0),
  ("Secrets Manager (app + RDS-managed master)", f"2 x {P['secret']} x {H}/{MONTH}", 2*P['secret']*frac),
  ("CloudWatch Logs ingest (assume 2 GB)", f"2 GB x {P['logs_in']}", 2*P['logs_in']),
  ("CloudWatch Logs storage", f"2 GB x {P['logs_store']} x {H}/{MONTH}", 2*P['logs_store']*frac),
  ("CloudWatch alarms (5)", f"5 x {P['alarm']} x {H}/{MONTH}", 5*P['alarm']*frac),
  ("CloudWatch dashboard (1; free tier covers 3)", f"1 x {P['dashboard']} x {H}/{MONTH}, worst case", 1*P['dashboard']*frac),
  ("S3: state, ALB and CDN logs (assume 2 GB)", f"2 GB x {P['s3']} x {H}/{MONTH}", 2*P['s3']*frac),
  ("ECR images (assume 1 GB kept)", f"1 GB x {P['ecr']} x {H}/{MONTH}", 1*P['ecr']*frac),
  ("CloudFront (5 GB, 100k HTTPS; free tier 1 TB/10M)", f"5 x {P['cf_gb']} + 100000 x {P['cf_req']:.6f}, worst case", 5*P['cf_gb'] + 100000*P['cf_req']),
]
total = sum(r[2] for r in rows)
print("| Item | Quantity x unit price (USD) | 7-day USD |\n| --- | --- | ---: |")
for name, formula, cost in rows: print(f"| {name} | {formula} | {cost:.2f} |")
print(f"| **Total (before credits and tax)** | | **{total:.2f}** |")
print(f"\nTarget 50.00; headroom {50-total:.2f} ({(total/50)*100:.0f}% of target)")
per_day = (4*24*(0.25*P['vcpu']+0.5*P['gb']+P['ipv4']) + 24*(P['alb']+P['lcu']+P['rds_maz'])
           + (20*P['gp3_maz'] + 2*P['secret'] + 5*P['alarm'] + P['dashboard'] + 3*P['s3'] + P['ecr'])*24/MONTH)
print(f"Each extra hosted day (steady state): {per_day:.2f}")
big = {k:c for k,_,c in rows}
top = sorted(rows, key=lambda r:-r[2])[:4]
print("Largest items:", ", ".join(f"{n} {c:.2f}" for n,_,c in top))
print(f"Retained after teardown: state bucket + one final snapshot (~1 GB x {P['backup']}) = {1*P['backup']+0.1*P['s3']:.2f}/month")
