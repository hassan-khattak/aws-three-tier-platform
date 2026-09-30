# One private repository per service. Tags are immutable and deployments use
# digests, so a pushed release can never be silently replaced.
resource "aws_ecr_repository" "service" {
  for_each             = toset(local.services)
  name                 = "${var.project}/${each.key}"
  image_tag_mutability = "IMMUTABLE"
  force_delete         = var.ecr_force_delete

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }
}

# Far above the number of releases in the hosting window, so the running and
# rollback digests are never expired.
resource "aws_ecr_lifecycle_policy" "service" {
  for_each   = aws_ecr_repository.service
  repository = each.value.name
  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep the newest ${var.image_retention_count} images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = var.image_retention_count
      }
      action = { type = "expire" }
    }]
  })
}
