output "aws_region" {
  value = var.region
}

output "vpc_id" {
  value = aws_vpc.main.id
}

output "public_subnet_ids" {
  value = aws_subnet.public[*].id
}

output "private_subnet_ids" {
  value = aws_subnet.private[*].id
}

output "availability_zone_ids" {
  value = aws_subnet.private[*].availability_zone_id
}

output "alb_security_group_id" {
  value = aws_security_group.alb.id
}

output "web_security_group_id" {
  value = aws_security_group.web.id
}

output "api_security_group_id" {
  value = aws_security_group.api.id
}

output "db_security_group_id" {
  value = aws_security_group.db.id
}

output "probe_security_group_id" {
  value = aws_security_group.probe.id
}

output "web_repository_url" {
  value = aws_ecr_repository.service["web"].repository_url
}

output "api_repository_url" {
  value = aws_ecr_repository.service["api"].repository_url
}

output "execution_role_arns" {
  value = { for k, r in aws_iam_role.execution : k => r.arn }
}

output "task_role_arns" {
  value = { for k, r in aws_iam_role.task : k => r.arn }
}

output "db_app_secret_arn" {
  description = "ARN only; the value is never exposed by Terraform."
  value       = aws_secretsmanager_secret.db_app.arn
}

output "ci_role_arns" {
  description = "Roles for GitHub Actions jobs: plan (any branch), release and infra (release branch only)."
  value       = { for k, r in aws_iam_role.ci : k => r.arn }
}

output "db_generations" {
  description = "Per generation: identifier, endpoint, port, engine version and RDS-managed master secret ARN."
  value = { for k, db in aws_db_instance.generation : k => {
    identifier        = db.identifier
    endpoint          = db.address
    port              = db.port
    engine_version    = db.engine_version_actual
    master_secret_arn = db.master_user_secret[0].secret_arn
  } }
}

output "active_db_generation" {
  value = var.active_db_generation
}

output "cluster_name" {
  value = aws_ecs_cluster.main.name
}

output "log_groups" {
  value = concat([for g in aws_cloudwatch_log_group.ecs : g.name], [for g in aws_cloudwatch_log_group.db : g.name])
}

output "operator_task_definition" {
  value = try(aws_ecs_task_definition.operator[0].arn, null)
}

output "alb_arn" {
  value = aws_lb.internal.arn
}

output "alb_dns_name" {
  value = aws_lb.internal.dns_name
}

output "alb_listener_arn" {
  value = aws_lb_listener.http.arn
}

output "target_group_arns" {
  value = { for k, tg in aws_lb_target_group.service : k => tg.arn }
}

output "service_names" {
  value = { for k, s in aws_ecs_service.service : k => s.name }
}

output "alb_log_bucket" {
  value = aws_s3_bucket.alb_logs.bucket
}

output "probe_task_definition" {
  value = try(aws_ecs_task_definition.probe[0].arn, null)
}

output "public_base_url" {
  value = "https://${aws_cloudfront_distribution.main.domain_name}"
}

output "cloudfront_distribution_id" {
  value = aws_cloudfront_distribution.main.id
}

output "cdn_log_group" {
  value = aws_cloudwatch_log_group.cdn.name
}

output "dashboard_url" {
  value = "https://${var.region}.console.aws.amazon.com/cloudwatch/home?region=${var.region}#dashboards/dashboard/${aws_cloudwatch_dashboard.main.dashboard_name}"
}

output "alarm_topic_arn" {
  value = aws_sns_topic.alarms.arn
}

output "service_task_definitions" {
  description = "Revisions registered by Terraform (configuration releases attach them with deploy.sh --revision)."
  value       = { for k, td in aws_ecs_task_definition.service : k => td.arn }
}

output "backup_vault" {
  value = aws_backup_vault.main.name
}

output "backup_role_arn" {
  value = aws_iam_role.backup.arn
}
