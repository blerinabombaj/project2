# modules/ecr/main.tf
#
# Creates one ECR (Elastic Container Registry) repository per microservice.
#
# WHY ECR INSTEAD OF DOCKER HUB?
#   Docker Hub rate-limits unauthenticated pulls and requires credentials
#   for private images. ECR is private by default, lives inside your AWS account,
#   and your EKS nodes can pull from it without extra credentials because
#   they inherit the node IAM role (which we grant ECR read access).
#
# WHAT THIS MODULE CREATES:
#   For each name in var.repository_names (api-gateway, user-service, order-service):
#     - One ECR repository
#     - A lifecycle policy that auto-deletes old images (keeps storage costs down)
#
# WHY USE A MODULE?
#   Without a module you'd repeat the same aws_ecr_repository + lifecycle policy
#   block three times. With a module you write it once and call it once.
#   When you add a 4th service, you just add its name to the list.

resource "aws_ecr_repository" "this" {
  # for_each turns a list into a map so Terraform creates one resource per item.
  # After this, each repo is addressed as aws_ecr_repository.this["api-gateway"], etc.
  for_each = toset(var.repository_names)

  name = "${var.project_name}/${each.key}" # e.g. "platform/api-gateway"

  # IMMUTABLE TAGS: once you push an image tagged "v1.0.0", that tag can never
  # be overwritten. Forces you to always push with a new tag (e.g. git SHA).
  # Mutable tags let someone silently replace "latest" with a broken image.
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    # ECR will automatically scan images for known CVEs when pushed.
    # Results appear in the ECR console. Trivy in CI (step 4) does a more
    # thorough scan BEFORE push — this is your backstop.
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }
}

# ── Lifecycle policy ───────────────────────────────────────────────────────────
#
# ECR charges $0.10/GB/month for storage beyond the free 500MB.
# Each image is ~100-200MB. Without cleanup, you'd accumulate hundreds of
# images from CI builds and pay for storage you never use.
#
# This policy says: keep only the most recent N images. Delete the rest.

resource "aws_ecr_lifecycle_policy" "this" {
  for_each   = aws_ecr_repository.this
  repository = each.value.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Keep only the last ${var.image_retention_count} images"
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = var.image_retention_count
        }
        action = {
          type = "expire"
        }
      }
    ]
  })
}
