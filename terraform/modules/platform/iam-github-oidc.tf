# Lets GitHub Actions assume an AWS role via OIDC - no long-lived access keys in CI.
module "github_oidc_provider" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-github-oidc-provider"
  version = "~> 5.48"
}

resource "aws_iam_policy" "ci" {
  name        = "${local.name}-ci"
  description = "Push access to the app ECR repos and read access to describe the EKS cluster"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ECRAuth"
        Effect   = "Allow"
        Action   = ["ecr:GetAuthorizationToken"]
        Resource = "*"
      },
      {
        Sid    = "ECRPush"
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage",
          "ecr:PutImage",
          "ecr:InitiateLayerUpload",
          "ecr:UploadLayerPart",
          "ecr:CompleteLayerUpload",
        ]
        Resource = [for repo in aws_ecr_repository.this : repo.arn]
      },
      {
        Sid      = "EKSDescribe"
        Effect   = "Allow"
        Action   = ["eks:DescribeCluster"]
        Resource = module.eks.cluster_arn
      },
    ]
  })

  tags = local.tags
}

module "github_actions_role" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-github-oidc-role"
  version = "~> 5.48"

  name = "${local.name}-github-actions"

  subjects = [
    "repo:${var.github_repo}:*",
  ]

  policies = {
    ci = aws_iam_policy.ci.arn
  }

  tags = local.tags
}
