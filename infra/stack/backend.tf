# Partial configuration: terraform init -backend-config=backend.hcl
# (see backend.hcl.example). Key: stack/terraform.tfstate, native S3 locking.
terraform {
  backend "s3" {}
}
