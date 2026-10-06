variable "region" {
  description = "Region for all regional resources."
  type        = string
  default     = "us-east-1"
}

variable "project" {
  description = "Short project name used in resource names and tags."
  type        = string
  default     = "three-tier"
}

variable "availability_zone_ids" {
  description = "Two AZ IDs (not names). use1-az3 does not support CloudFront VPC origins."
  type        = list(string)
  default     = ["use1-az1", "use1-az2"]

  validation {
    condition     = length(var.availability_zone_ids) == 2 && !contains(var.availability_zone_ids, "use1-az3")
    error_message = "Provide exactly two AZ IDs, excluding use1-az3."
  }
}

variable "vpc_cidr" {
  description = "VPC range. Subnets: public 10.42.0-1.0/24, private 10.42.10-11.0/24."
  type        = string
  default     = "10.42.0.0/16"
}

variable "image_retention_count" {
  description = "Images kept per repository; must exceed releases in the hosting window."
  type        = number
  default     = 20
}

variable "github_repository" {
  description = "Only this repository's workflows may assume the CI roles (owner/name)."
  type        = string
  default     = "hassan-khattak/aws-three-tier-platform"
}

variable "github_release_branch" {
  description = "Branch whose workflow runs may release and apply infrastructure."
  type        = string
  default     = "main"
}

variable "db_generations" {
  description = <<-EOT
    Database generations by name. The API uses var.active_db_generation.
    A planned engine update adds a generation restored from the serving one
    (restore_from), upgrades it with apply_immediately, moves the API to it,
    and later removes the old generation.
  EOT
  type = map(object({
    engine_version      = string
    restore_from        = optional(string)
    apply_immediately   = optional(bool, false)
    deletion_protection = optional(bool, true)
  }))
  # Planned update in progress: green (restored from blue, upgraded to 16.15)
  # is prepared alongside the serving blue generation.
  default = {
    blue  = { engine_version = "16.14" }
    green = { engine_version = "16.15", restore_from = "blue", apply_immediately = true }
  }
}

variable "active_db_generation" {
  description = "Generation the API connects to."
  type        = string
  default     = "green"
}

variable "db_instance_class" {
  type    = string
  default = "db.t4g.micro"
}

variable "db_backup_retention_days" {
  type    = number
  default = 7
}

variable "log_retention_days" {
  type    = number
  default = 7
}

variable "access_log_retention_days" {
  type    = number
  default = 14
}

# Teardown switches; keep the safe defaults for normal operation.
variable "db_deletion_protection" {
  type    = bool
  default = true
}

variable "ecr_force_delete" {
  description = "Allow destroying repositories that still contain images (teardown only)."
  type        = bool
  default     = false
}

variable "services_enabled" {
  description = "Create the web/API services. Set false for the first apply in a new account, until images exist and the database login is initialized."
  type        = bool
  default     = true
}

variable "backup_retention_days" {
  description = "Days to keep AWS Backup recovery points of mutable storage."
  type        = number
  default     = 7
}
