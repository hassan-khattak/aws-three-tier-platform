# One-off operator task: runs a helper from the published API image with the
# API security group. It exists only while running and has no HTTP port.
locals {
  images    = try(jsondecode(file("${path.module}/../../deploy/images.json")), {})
  active_db = aws_db_instance.generation[var.active_db_generation]
}

resource "aws_ecs_task_definition" "operator" {
  count = contains(keys(local.images), "api") ? 1 : 0

  family                   = "${var.project}-operator"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = "256"
  memory                   = "512"
  execution_role_arn       = aws_iam_role.execution["operator"].arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }

  container_definitions = jsonencode([{
    name                   = "operator"
    image                  = try(local.images["api"].image, "")
    essential              = true
    readonlyRootFilesystem = true
    # The image's ENTRYPOINT is the API launcher; replace it, since a
    # command alone would only be passed to the launcher as arguments.
    entryPoint = ["node"]
    command    = ["scripts/init-database.js"]
    environment = [
      { name = "DBHOST", value = local.active_db.address },
      { name = "DBPORT", value = tostring(local.active_db.port) },
      { name = "DB", value = local.db_name },
      { name = "APP_USER", value = "assessment_app" },
    ]
    # Injected by ECS at start; never in Terraform variables, state values or logs.
    secrets = [
      { name = "ADMIN_USER", valueFrom = "${local.active_db.master_user_secret[0].secret_arn}:username::" },
      { name = "ADMIN_PASS", valueFrom = "${local.active_db.master_user_secret[0].secret_arn}:password::" },
      { name = "APP_PASS", valueFrom = "${aws_secretsmanager_secret.db_app.arn}:password::" },
    ]
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        awslogs-group         = aws_cloudwatch_log_group.ecs["operator"].name
        awslogs-region        = var.region
        awslogs-stream-prefix = "operator"
      }
    }
  }])
}

# One-off private probe through the internal ALB. Inline script so the probe
# needs no image change; no secrets, probe security group only.
locals {
  probe_script = <<-JS
    const base = process.env.PROBE_URL;
    const deadline = (ms) => AbortSignal.timeout(ms);
    const checks = [
      ['web_page', '/', (r, t) => r.status === 200 && /Welcome, it's /.test(t) && /<pre>[0-9a-f-]{36}<\/pre>/.test(t)],
      ['api_status', '/api/status', (r, t) => { const b = JSON.parse(t); return r.status === 200 && Array.isArray(b) && b.length === 1 && Math.abs(Date.now() - Date.parse(b[0].time)) < 60000 && /^[0-9a-f-]{36}$/.test(b[0].request_uuid); }],
      ['web_ready', '/health/ready', (r) => r.status === 200],
    ];
    (async () => {
      let failed = 0;
      for (const [name, path, ok] of checks) {
        const started = Date.now();
        try {
          const r = await fetch(base + path, { signal: deadline(8000), redirect: 'manual' });
          const t = await r.text();
          const pass = ok(r, t);
          failed += pass ? 0 : 1;
          console.log(JSON.stringify({ check: name, path, status: r.status, ms: Date.now() - started, pass }));
        } catch (e) {
          failed++;
          console.log(JSON.stringify({ check: name, path, error: e.name, ms: Date.now() - started, pass: false }));
        }
      }
      console.log(JSON.stringify({ probe: 'complete', failed }));
      process.exitCode = failed ? 1 : 0;
    })();
  JS
}

resource "aws_ecs_task_definition" "probe" {
  count = contains(keys(local.images), "api") ? 1 : 0

  family                   = "${var.project}-probe"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = "256"
  memory                   = "512"
  execution_role_arn       = aws_iam_role.execution["operator"].arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }

  container_definitions = jsonencode([{
    name                   = "probe"
    image                  = try(local.images["api"].image, "")
    essential              = true
    readonlyRootFilesystem = true
    entryPoint             = ["node", "-e"]
    command                = [local.probe_script]
    environment            = [{ name = "PROBE_URL", value = "http://${aws_lb.internal.dns_name}" }]
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        awslogs-group         = aws_cloudwatch_log_group.ecs["operator"].name
        awslogs-region        = var.region
        awslogs-stream-prefix = "probe"
      }
    }
  }])
}
