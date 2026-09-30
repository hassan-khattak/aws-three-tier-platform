# One group per role. Every allowed edge is a separate rule below; nothing is
# open to a public CIDR on an application port. CloudFront origin ingress to
# the ALB group is added with the CDN.
resource "aws_security_group" "alb" {
  name        = "${var.project}-alb"
  description = "Internal ALB"
  vpc_id      = aws_vpc.main.id
  tags        = { Name = "${var.project}-alb" }
}

resource "aws_security_group" "web" {
  name        = "${var.project}-web"
  description = "Web tasks"
  vpc_id      = aws_vpc.main.id
  tags        = { Name = "${var.project}-web" }
}

resource "aws_security_group" "api" {
  name        = "${var.project}-api"
  description = "API tasks and authorized DB initialization tasks"
  vpc_id      = aws_vpc.main.id
  tags        = { Name = "${var.project}-api" }
}

resource "aws_security_group" "db" {
  name        = "${var.project}-db"
  description = "PostgreSQL"
  vpc_id      = aws_vpc.main.id
  tags        = { Name = "${var.project}-db" }
}

resource "aws_security_group" "probe" {
  name        = "${var.project}-probe"
  description = "One-off private probe tasks"
  vpc_id      = aws_vpc.main.id
  tags        = { Name = "${var.project}-probe" }
}

locals {
  app_port = 3000
  alb_port = 80
  db_port  = 5432
}

# ALB -> tasks
resource "aws_vpc_security_group_egress_rule" "alb_to_web" {
  security_group_id            = aws_security_group.alb.id
  referenced_security_group_id = aws_security_group.web.id
  ip_protocol                  = "tcp"
  from_port                    = local.app_port
  to_port                      = local.app_port
  description                  = "ALB to web tasks"
}

resource "aws_vpc_security_group_egress_rule" "alb_to_api" {
  security_group_id            = aws_security_group.alb.id
  referenced_security_group_id = aws_security_group.api.id
  ip_protocol                  = "tcp"
  from_port                    = local.app_port
  to_port                      = local.app_port
  description                  = "ALB to API tasks"
}

resource "aws_vpc_security_group_ingress_rule" "web_from_alb" {
  security_group_id            = aws_security_group.web.id
  referenced_security_group_id = aws_security_group.alb.id
  ip_protocol                  = "tcp"
  from_port                    = local.app_port
  to_port                      = local.app_port
  description                  = "From ALB"
}

resource "aws_vpc_security_group_ingress_rule" "api_from_alb" {
  security_group_id            = aws_security_group.api.id
  referenced_security_group_id = aws_security_group.alb.id
  ip_protocol                  = "tcp"
  from_port                    = local.app_port
  to_port                      = local.app_port
  description                  = "From ALB"
}

# Web server-side calls and probes reach the API through the ALB.
resource "aws_vpc_security_group_ingress_rule" "alb_from_web" {
  security_group_id            = aws_security_group.alb.id
  referenced_security_group_id = aws_security_group.web.id
  ip_protocol                  = "tcp"
  from_port                    = local.alb_port
  to_port                      = local.alb_port
  description                  = "Web tasks calling the API"
}

resource "aws_vpc_security_group_ingress_rule" "alb_from_probe" {
  security_group_id            = aws_security_group.alb.id
  referenced_security_group_id = aws_security_group.probe.id
  ip_protocol                  = "tcp"
  from_port                    = local.alb_port
  to_port                      = local.alb_port
  description                  = "Private probe tasks"
}

# API -> DB
resource "aws_vpc_security_group_ingress_rule" "db_from_api" {
  security_group_id            = aws_security_group.db.id
  referenced_security_group_id = aws_security_group.api.id
  ip_protocol                  = "tcp"
  from_port                    = local.db_port
  to_port                      = local.db_port
  description                  = "From API tasks"
}

# Task outbound: HTTPS for ECR, CloudWatch Logs and Secrets Manager over the
# internet gateway; HTTP to the internal ALB; API to PostgreSQL.
resource "aws_vpc_security_group_egress_rule" "https_out" {
  for_each          = { web = aws_security_group.web.id, api = aws_security_group.api.id, probe = aws_security_group.probe.id }
  security_group_id = each.value
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  description       = "AWS service endpoints over HTTPS"
}

resource "aws_vpc_security_group_egress_rule" "to_alb" {
  for_each                     = { web = aws_security_group.web.id, probe = aws_security_group.probe.id }
  security_group_id            = each.value
  referenced_security_group_id = aws_security_group.alb.id
  ip_protocol                  = "tcp"
  from_port                    = local.alb_port
  to_port                      = local.alb_port
  description                  = "To internal ALB"
}

resource "aws_vpc_security_group_egress_rule" "api_to_db" {
  security_group_id            = aws_security_group.api.id
  referenced_security_group_id = aws_security_group.db.id
  ip_protocol                  = "tcp"
  from_port                    = local.db_port
  to_port                      = local.db_port
  description                  = "To PostgreSQL"
}
