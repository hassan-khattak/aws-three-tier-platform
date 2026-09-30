# Application database login ({"username": ..., "password": ...}). Only the
# container is created here; the value is set when the database role is
# created, never through Terraform variables or state. Only the API
# execution role can read it. The master credential is RDS-managed and never
# injected into application tasks.
resource "aws_secretsmanager_secret" "db_app" {
  name                    = "${var.project}/db/app"
  description             = "PostgreSQL login for the API (read-only application role)"
  recovery_window_in_days = 7
}
