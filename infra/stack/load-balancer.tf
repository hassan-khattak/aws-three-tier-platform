# One internal ALB in the private subnets: /api and /api/* go to the API,
# everything else to web. CloudFront reaches it later through a VPC origin.
resource "aws_lb" "internal" {
  name                       = "${var.project}-internal"
  internal                   = true
  load_balancer_type         = "application"
  subnets                    = aws_subnet.private[*].id
  security_groups            = [aws_security_group.alb.id]
  idle_timeout               = 30
  drop_invalid_header_fields = true

  access_logs {
    bucket  = aws_s3_bucket.alb_logs.id
    prefix  = "alb"
    enabled = true
  }

  depends_on = [aws_s3_bucket_policy.alb_logs]
}

resource "aws_lb_target_group" "service" {
  for_each = toset(local.services)

  name                 = "${var.project}-${each.key}"
  port                 = local.app_port
  protocol             = "HTTP"
  target_type          = "ip"
  vpc_id               = aws_vpc.main.id
  deregistration_delay = 15

  # Process liveness only: a shared dependency outage must not make the ALB
  # (and ECS) replace every otherwise healthy task. Readiness is probed separately.
  health_check {
    path                = "/health/live"
    matcher             = "200"
    interval            = 15
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.internal.arn
  port              = local.alb_port
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.service["web"].arn
  }
}

resource "aws_lb_listener_rule" "api" {
  listener_arn = aws_lb_listener.http.arn
  priority     = 10

  condition {
    path_pattern {
      values = ["/api", "/api/*"]
    }
  }

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.service["api"].arn
  }
}

# Access logs: private, SSE-S3 (required for ALB log delivery), 14 days.
resource "aws_s3_bucket" "alb_logs" {
  bucket        = "${var.project}-alb-logs-${data.aws_caller_identity.current.account_id}-${var.region}"
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "alb_logs" {
  bucket                  = aws_s3_bucket.alb_logs.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "alb_logs" {
  bucket = aws_s3_bucket.alb_logs.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "alb_logs" {
  bucket = aws_s3_bucket.alb_logs.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "alb_logs" {
  bucket = aws_s3_bucket.alb_logs.id
  rule {
    id     = "expire-access-logs"
    status = "Enabled"
    filter {}
    expiration {
      days = var.access_log_retention_days
    }
  }
}

# us-east-1 predates the log-delivery service principal, so delivery is
# granted to the regional Elastic Load Balancing account.
data "aws_elb_service_account" "current" {}

data "aws_iam_policy_document" "alb_logs" {
  statement {
    sid       = "AlbLogDelivery"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.alb_logs.arn}/alb/AWSLogs/${data.aws_caller_identity.current.account_id}/*"]
    principals {
      type        = "AWS"
      identifiers = [data.aws_elb_service_account.current.arn]
    }
  }
  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.alb_logs.arn, "${aws_s3_bucket.alb_logs.arn}/*"]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "alb_logs" {
  bucket     = aws_s3_bucket.alb_logs.id
  policy     = data.aws_iam_policy_document.alb_logs.json
  depends_on = [aws_s3_bucket_public_access_block.alb_logs]
}
