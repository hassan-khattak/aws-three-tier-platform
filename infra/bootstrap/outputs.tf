output "state_bucket" {
  description = "Terraform state bucket for the bootstrap and main stack."
  value       = aws_s3_bucket.state.bucket
}

output "region" {
  value = var.region
}
