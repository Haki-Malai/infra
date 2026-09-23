resource "aws_iam_openid_connect_provider" "github" {
  count          = var.github_oidc_provider_arn == "" ? 1 : 0
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
  tags           = local.packetloss_tags
}

data "github_user" "owner" {
  username = var.github_owner
}

data "github_repository" "packetloss" {
  full_name = "${var.github_owner}/${var.packetloss_repository}"
}

resource "aws_iam_role" "packetloss_deploy" {
  for_each = var.packetloss_stages
  name     = "packetloss-${each.key}-deploy"
  path     = "/packetloss/"
  tags     = merge(local.packetloss_tags, { Stage = each.key })
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Federated = var.github_oidc_provider_arn != "" ? var.github_oidc_provider_arn : aws_iam_openid_connect_provider.github[0].arn
      }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          "token.actions.githubusercontent.com:sub" = "repo:${var.github_owner}@${data.github_user.owner.id}/${var.packetloss_repository}@${data.github_repository.packetloss.repo_id}:environment:${each.key}"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy" "packetloss_deploy" {
  for_each = var.packetloss_stages
  name     = "publish-site"
  role     = aws_iam_role.packetloss_deploy[each.key].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:ListBucket", "s3:GetBucketLocation"]
        Resource = aws_s3_bucket.packetloss[each.key].arn
      },
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject"]
        Resource = "${aws_s3_bucket.packetloss[each.key].arn}/*"
      },
      {
        Effect   = "Allow"
        Action   = ["cloudfront:CreateInvalidation", "cloudfront:GetInvalidation"]
        Resource = aws_cloudfront_distribution.packetloss[each.key].arn
      },
      {
        Effect   = "Allow"
        Action   = ["lambda:GetFunctionConfiguration", "lambda:UpdateFunctionCode"]
        Resource = aws_lambda_function.packetloss_api[each.key].arn
      }
    ]
  })
}

resource "github_repository_environment" "packetloss" {
  for_each    = var.packetloss_stages
  repository  = var.packetloss_repository
  environment = each.key
  deployment_branch_policy {
    protected_branches     = false
    custom_branch_policies = true
  }
}

resource "github_repository_environment_deployment_policy" "packetloss" {
  for_each       = var.packetloss_stages
  repository     = var.packetloss_repository
  environment    = github_repository_environment.packetloss[each.key].environment
  branch_pattern = each.value.branch
}

locals {
  packetloss_environment_variables = merge([
    for stage, settings in var.packetloss_stages : {
      for name, value in {
        AWS_REGION                 = var.aws_region
        AWS_ROLE_ARN               = aws_iam_role.packetloss_deploy[stage].arn
        S3_BUCKET                  = aws_s3_bucket.packetloss[stage].id
        CLOUDFRONT_DISTRIBUTION_ID = aws_cloudfront_distribution.packetloss[stage].id
        SITE_URL                   = "https://${local.packetloss_domains[stage]}"
        BUILD_MODE                 = settings.build_mode
        VITE_GAME_ENV              = settings.vite_game_env
        VITE_API_URL               = "https://${local.packetloss_api_domains[stage]}"
        LAMBDA_FUNCTION_NAME       = aws_lambda_function.packetloss_api[stage].function_name
      } : "${stage}/${name}" => { stage = stage, name = name, value = value }
    }
  ]...)
}

resource "github_actions_environment_variable" "packetloss" {
  for_each      = local.packetloss_environment_variables
  repository    = var.packetloss_repository
  environment   = github_repository_environment.packetloss[each.value.stage].environment
  variable_name = each.value.name
  value         = each.value.value
}

# Remember the approved cutover so later infrastructure runs preserve its routing.
resource "github_actions_variable" "packetloss_production_dns_enabled" {
  repository    = var.infrastructure_repository
  variable_name = "PACKETLOSS_PRODUCTION_DNS_ENABLED"
  value         = tostring(var.packetloss_production_dns_enabled)
}
