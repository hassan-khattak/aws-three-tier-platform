# State lives in the bucket this configuration creates, under
# bootstrap/terraform.tfstate. Partial configuration: see backend.hcl.example.
#
# First run in a new account (the bucket does not exist yet):
#   cp local_override.tf.example local_override.tf
#   terraform init && terraform apply
#   rm local_override.tf
#   terraform init -migrate-state -backend-config=backend.hcl
terraform {
  backend "s3" {}
}
