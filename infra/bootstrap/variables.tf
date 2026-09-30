variable "region" {
  description = "Region for the state bucket."
  type        = string
  default     = "us-east-1"
}

variable "project" {
  description = "Short project name used in resource names and tags."
  type        = string
  default     = "three-tier"
}

variable "noncurrent_version_days" {
  description = "Days to keep superseded state versions for recovery."
  type        = number
  default     = 90
}
