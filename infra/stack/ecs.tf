resource "aws_ecs_cluster" "main" {
  name = var.project

  # Standard ECS/ALB/RDS metrics are enough for this deployment; Container
  # Insights adds per-task metrics at extra cost.
  setting {
    name  = "containerInsights"
    value = "disabled"
  }
}

resource "aws_ecs_cluster_capacity_providers" "main" {
  cluster_name       = aws_ecs_cluster.main.name
  capacity_providers = ["FARGATE"]

  default_capacity_provider_strategy {
    capacity_provider = "FARGATE"
    weight            = 1
  }
}

# Names match the scopes granted to the execution roles.
resource "aws_cloudwatch_log_group" "ecs" {
  for_each          = toset(["web", "api", "operator"])
  name              = "/ecs/${var.project}/${each.key}"
  retention_in_days = var.log_retention_days
}
