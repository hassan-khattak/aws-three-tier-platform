# Task definitions start from the image digests in deploy/images.json. After
# the first apply, releases register new revisions from the current one (new
# image only) and update the service; Terraform then ignores task_definition
# and desired_count, which the release and runtime scripts own.
locals {
  service_env = {
    web = [
      { name = "NODE_ENV", value = "production" },
      { name = "PORT", value = tostring(local.app_port) },
      { name = "API_HOST", value = "http://${aws_lb.internal.dns_name}" },
    ]
    api = [
      { name = "NODE_ENV", value = "production" },
      { name = "PORT", value = tostring(local.app_port) },
      { name = "DBHOST", value = local.active_db.address },
      { name = "DBPORT", value = tostring(local.active_db.port) },
      { name = "DB", value = local.db_name },
      { name = "DB_SSL", value = "true" },
    ]
  }
  service_secrets = {
    web = []
    api = [
      { name = "DBUSER", valueFrom = "${aws_secretsmanager_secret.db_app.arn}:username::" },
      { name = "DBPASS", valueFrom = "${aws_secretsmanager_secret.db_app.arn}:password::" },
    ]
  }
  # Serving tasks exist only once images are published and, on a first
  # deployment, after the database login has been initialized
  # (services_enabled=false until then; see README "Deploy").
  deployable = { for s in local.services : s => s if var.services_enabled && contains(keys(local.images), s) }
}

resource "aws_ecs_task_definition" "service" {
  for_each = local.deployable

  family                   = "${var.project}-${each.key}"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = "256"
  memory                   = "512"
  execution_role_arn       = aws_iam_role.execution[each.key].arn
  task_role_arn            = aws_iam_role.task[each.key].arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }

  container_definitions = jsonencode([{
    name                   = each.key
    image                  = local.images[each.key].image
    essential              = true
    readonlyRootFilesystem = true
    stopTimeout            = 30
    portMappings           = [{ containerPort = local.app_port, protocol = "tcp" }]
    environment            = local.service_env[each.key]
    secrets                = local.service_secrets[each.key]
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        awslogs-group         = aws_cloudwatch_log_group.ecs[each.key].name
        awslogs-region        = var.region
        awslogs-stream-prefix = each.key
      }
    }
  }])
}

resource "aws_ecs_service" "service" {
  for_each = local.deployable

  name                   = each.key
  cluster                = aws_ecs_cluster.main.id
  task_definition        = aws_ecs_task_definition.service[each.key].arn
  desired_count          = 2
  launch_type            = "FARGATE"
  platform_version       = "1.4.0"
  propagate_tags         = "SERVICE"
  enable_execute_command = false

  # Replacement tasks must be healthy before old ones drain; failed releases
  # roll back automatically.
  deployment_minimum_healthy_percent = 100
  deployment_maximum_percent         = 200
  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }
  health_check_grace_period_seconds = 90
  availability_zone_rebalancing     = "ENABLED"

  network_configuration {
    subnets          = aws_subnet.public[*].id
    security_groups  = [each.key == "web" ? aws_security_group.web.id : aws_security_group.api.id]
    assign_public_ip = true
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.service[each.key].arn
    container_name   = each.key
    container_port   = local.app_port
  }

  wait_for_steady_state = true

  lifecycle {
    ignore_changes = [task_definition, desired_count]
  }

  depends_on = [aws_lb_listener.http, aws_lb_listener_rule.api]
}
