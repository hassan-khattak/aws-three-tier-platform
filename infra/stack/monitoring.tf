# One dashboard across tiers, a few actionable alarms and saved log queries.
# Uses native metrics only (no Container Insights). Alarms notify an SNS
# topic; subscribe an address with:
#   aws sns subscribe --topic-arn <alarm_topic_arn> --protocol email --notification-endpoint you@example.com
locals {
  alb_dim = aws_lb.internal.arn_suffix
  tg_dim  = { for k, tg in aws_lb_target_group.service : k => tg.arn_suffix }
  db_id   = local.active_db.identifier
  cdn_id  = aws_cloudfront_distribution.main.id
  region  = var.region
  services_widgets = [for s in local.services : {
    type = "metric", width = 8, height = 6
    properties = {
      title = "ECS ${s}: CPU / memory %", region = local.region, stat = "Average", period = 60, view = "timeSeries"
      metrics = [
        ["AWS/ECS", "CPUUtilization", "ClusterName", aws_ecs_cluster.main.name, "ServiceName", s],
        [".", "MemoryUtilization", ".", ".", ".", "."],
      ]
    }
  }]
}

resource "aws_cloudwatch_dashboard" "main" {
  dashboard_name = var.project
  dashboard_body = jsonencode({
    widgets = concat([
      {
        type = "metric", width = 8, height = 6
        properties = {
          title = "CloudFront: requests and 5xx %", region = "us-east-1", period = 60, view = "timeSeries"
          metrics = [
            ["AWS/CloudFront", "Requests", "DistributionId", local.cdn_id, "Region", "Global", { stat = "Sum" }],
            [".", "5xxErrorRate", ".", ".", ".", ".", { stat = "Average", yAxis = "right" }],
          ]
        }
      },
      {
        type = "metric", width = 8, height = 6
        properties = {
          title = "ALB: requests, target 5xx, ELB 5xx", region = local.region, stat = "Sum", period = 60, view = "timeSeries"
          metrics = [
            ["AWS/ApplicationELB", "RequestCount", "LoadBalancer", local.alb_dim],
            [".", "HTTPCode_Target_5XX_Count", ".", "."],
            [".", "HTTPCode_ELB_5XX_Count", ".", "."],
          ]
        }
      },
      {
        type = "metric", width = 8, height = 6
        properties = {
          title   = "ALB: target response time p95 (s)", region = local.region, stat = "p95", period = 60, view = "timeSeries"
          metrics = [for s in local.services : ["AWS/ApplicationELB", "TargetResponseTime", "LoadBalancer", local.alb_dim, "TargetGroup", local.tg_dim[s], { label = s }]]
        }
      },
      {
        type = "metric", width = 8, height = 6
        properties = {
          title   = "Healthy targets per service", region = local.region, stat = "Minimum", period = 60, view = "timeSeries"
          metrics = [for s in local.services : ["AWS/ApplicationELB", "HealthyHostCount", "TargetGroup", local.tg_dim[s], "LoadBalancer", local.alb_dim, { label = s }]]
        }
      },
      ], local.services_widgets, [
      {
        type = "metric", width = 8, height = 6
        properties = {
          title = "RDS: CPU % and connections", region = local.region, stat = "Average", period = 60, view = "timeSeries"
          metrics = [
            ["AWS/RDS", "CPUUtilization", "DBInstanceIdentifier", local.db_id],
            [".", "DatabaseConnections", ".", ".", { yAxis = "right" }],
          ]
        }
      },
      {
        type = "metric", width = 8, height = 6
        properties = {
          title = "RDS: read/write latency (s)", region = local.region, stat = "Average", period = 60, view = "timeSeries"
          metrics = [
            ["AWS/RDS", "ReadLatency", "DBInstanceIdentifier", local.db_id],
            [".", "WriteLatency", ".", "."],
          ]
        }
      },
      {
        type = "metric", width = 8, height = 6
        properties = {
          title   = "RDS: free storage (bytes)", region = local.region, stat = "Minimum", period = 300, view = "timeSeries"
          metrics = [["AWS/RDS", "FreeStorageSpace", "DBInstanceIdentifier", local.db_id]]
        }
      },
    ])
  })
}

resource "aws_sns_topic" "alarms" {
  name = "${var.project}-alarms"
}

resource "aws_cloudwatch_metric_alarm" "unhealthy_targets" {
  for_each            = toset(local.services)
  alarm_name          = "${var.project}-${each.key}-healthy-targets-below-2"
  alarm_description   = "Fewer than 2 healthy ${each.key} targets for 3 minutes."
  namespace           = "AWS/ApplicationELB"
  metric_name         = "HealthyHostCount"
  dimensions          = { TargetGroup = local.tg_dim[each.key], LoadBalancer = local.alb_dim }
  statistic           = "Minimum"
  period              = 60
  evaluation_periods  = 3
  threshold           = 2
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "breaching"
  alarm_actions       = [aws_sns_topic.alarms.arn]
  ok_actions          = [aws_sns_topic.alarms.arn]
}

resource "aws_cloudwatch_metric_alarm" "target_5xx" {
  alarm_name          = "${var.project}-alb-target-5xx"
  alarm_description   = "More than 10 target 5xx responses in 5 minutes."
  namespace           = "AWS/ApplicationELB"
  metric_name         = "HTTPCode_Target_5XX_Count"
  dimensions          = { LoadBalancer = local.alb_dim }
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 10
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alarms.arn]
  ok_actions          = [aws_sns_topic.alarms.arn]
}

resource "aws_cloudwatch_metric_alarm" "cdn_5xx_rate" {
  alarm_name          = "${var.project}-cloudfront-5xx-rate"
  alarm_description   = "CloudFront 5xx error rate above 5% for 5 minutes."
  namespace           = "AWS/CloudFront"
  metric_name         = "5xxErrorRate"
  dimensions          = { DistributionId = local.cdn_id, Region = "Global" }
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 1
  threshold           = 5
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alarms.arn]
  ok_actions          = [aws_sns_topic.alarms.arn]
}

resource "aws_cloudwatch_metric_alarm" "db_cpu" {
  alarm_name          = "${var.project}-db-cpu-high"
  alarm_description   = "Database CPU above 80% for 10 minutes."
  namespace           = "AWS/RDS"
  metric_name         = "CPUUtilization"
  dimensions          = { DBInstanceIdentifier = local.db_id }
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 2
  threshold           = 80
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alarms.arn]
  ok_actions          = [aws_sns_topic.alarms.arn]
}

# Saved Logs Insights queries (CloudWatch → Logs Insights → Queries).
resource "aws_cloudwatch_query_definition" "api_errors" {
  name            = "${var.project}/api-errors"
  log_group_names = [aws_cloudwatch_log_group.ecs["api"].name, aws_cloudwatch_log_group.ecs["web"].name]
  query_string    = <<-Q
    fields @timestamp, service, route, status, reason, duration_ms, request_id
    | filter level = "error" or status >= 500
    | sort @timestamp desc
    | limit 100
  Q
}

resource "aws_cloudwatch_query_definition" "slow_requests" {
  name            = "${var.project}/slow-requests"
  log_group_names = [aws_cloudwatch_log_group.ecs["api"].name, aws_cloudwatch_log_group.ecs["web"].name]
  query_string    = <<-Q
    fields @timestamp, service, route, status, duration_ms, request_id
    | filter event = "request_finished" and route not like /health/
    | stats count() as requests, avg(duration_ms) as avg_ms, pct(duration_ms, 95) as p95_ms, max(duration_ms) as max_ms by service, route, bin(5m)
  Q
}

resource "aws_cloudwatch_query_definition" "request_trace" {
  name            = "${var.project}/trace-request-id"
  log_group_names = [aws_cloudwatch_log_group.ecs["api"].name, aws_cloudwatch_log_group.ecs["web"].name]
  query_string    = <<-Q
    # Replace the ID: the API's request_id is the request_uuid shown on the page.
    fields @timestamp, service, event, route, status, reason, duration_ms
    | filter request_id = "00000000-0000-0000-0000-000000000000"
    | sort @timestamp asc
  Q
}

resource "aws_cloudwatch_query_definition" "lifecycle" {
  name            = "${var.project}/task-lifecycle"
  log_group_names = [aws_cloudwatch_log_group.ecs["api"].name, aws_cloudwatch_log_group.ecs["web"].name]
  query_string    = <<-Q
    fields @timestamp, service, event, reason, code, @logStream
    | filter event in ["startup_waiting", "server_listening", "startup_failed", "shutdown_started", "shutdown_complete", "shutdown_forced", "db_idle_error"]
    | sort @timestamp desc
    | limit 200
  Q
}
