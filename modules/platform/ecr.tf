# Private ECR repos for the two app images. CI pushes here via the GitHub OIDC role below.
resource "aws_ecr_repository" "this" {
  for_each = toset(["backend", "frontend"])

  name                 = "${var.project_name}-${each.key}"
  image_tag_mutability = "MUTABLE"
  # This project destroys the whole environment routinely (see the "ephemeral
  # infra" cost model in the README) - without force_delete, every single
  # destroy fails here and needs a manual image cleanup first.
  force_delete = true

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = local.tags
}

# Expire untagged images after a week to keep storage cost/clutter down.
resource "aws_ecr_lifecycle_policy" "this" {
  for_each = aws_ecr_repository.this

  repository = each.value.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Expire untagged images after 7 days"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 7
        }
        action = {
          type = "expire"
        }
      }
    ]
  })
}
