# PostgreSQL generations. Normally only "blue" exists; a planned engine update
# adds a second generation restored from a snapshot, moves the API to it, and
# removes the old one later. Each generation keeps its own identity.
locals {
  db_name        = "assessment"
  db_admin_user  = "dbadmin"
  db_generations = var.db_generations
}

resource "aws_db_subnet_group" "main" {
  name       = "${var.project}-db"
  subnet_ids = aws_subnet.private[*].id
}

resource "aws_db_parameter_group" "postgres16" {
  name        = "${var.project}-postgres16"
  family      = "postgres16"
  description = "TLS required; errors and slow statements only, no statement logging"

  parameter {
    name         = "rds.force_ssl"
    value        = "1"
    apply_method = "pending-reboot" # static parameter; set at creation
  }
  parameter {
    name  = "log_min_duration_statement"
    value = "1000"
  }
  parameter {
    name  = "log_connections"
    value = "1"
  }
  parameter {
    name  = "log_disconnections"
    value = "1"
  }
}

# Created before the instance so exports land in groups with retention set.
resource "aws_cloudwatch_log_group" "db" {
  for_each = { for pair in setproduct(keys(local.db_generations), ["postgresql", "upgrade"]) : "${pair[0]}-${pair[1]}" => pair }

  name              = "/aws/rds/instance/${var.project}-${each.value[0]}/${each.value[1]}"
  retention_in_days = var.log_retention_days
}

resource "aws_db_instance" "generation" {
  for_each = local.db_generations

  identifier     = "${var.project}-${each.key}"
  engine         = "postgres"
  engine_version = each.value.engine_version
  instance_class = var.db_instance_class
  multi_az       = true

  # A restored generation inherits the database name and master user.
  db_name                     = each.value.restore_from == null ? local.db_name : null
  username                    = each.value.restore_from == null ? local.db_admin_user : null
  manage_master_user_password = true # RDS keeps the master password in Secrets Manager

  allocated_storage     = 20
  max_allocated_storage = 0
  storage_type          = "gp3"
  storage_encrypted     = true

  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.db.id]
  publicly_accessible    = false
  port                   = 5432
  parameter_group_name   = aws_db_parameter_group.postgres16.name
  ca_cert_identifier     = "rds-ca-rsa2048-g1"

  backup_retention_period  = var.db_backup_retention_days
  backup_window            = "02:00-03:00"
  maintenance_window       = "sun:04:00-sun:05:00"
  copy_tags_to_snapshot    = true
  delete_automated_backups = false

  # Engine versions change only through the planned replacement procedure.
  auto_minor_version_upgrade  = false
  allow_major_version_upgrade = false
  apply_immediately           = each.value.apply_immediately

  # A replacement generation starts as a copy of the serving one.
  dynamic "restore_to_point_in_time" {
    for_each = each.value.restore_from == null ? [] : [each.value.restore_from]
    content {
      source_db_instance_identifier = "${var.project}-${restore_to_point_in_time.value}"
      use_latest_restorable_time    = true
    }
  }

  enabled_cloudwatch_logs_exports = ["postgresql", "upgrade"]
  performance_insights_enabled    = false

  deletion_protection       = var.db_deletion_protection && each.value.deletion_protection
  skip_final_snapshot       = false
  final_snapshot_identifier = "${var.project}-${each.key}-final"

  tags = { Generation = each.key }

  lifecycle {
    ignore_changes = [restore_to_point_in_time]
  }

  depends_on = [aws_cloudwatch_log_group.db]
}
