provider "aws" {
  alias  = "game_eu"
  region = "eu-central-1"
}

provider "aws" {
  alias  = "game_na"
  region = "us-east-1"
}

locals {
  game_tags = merge(local.packetloss_tags, { Stage = "prod", Component = "multiplayer" })
  game_regions = var.game_servers_enabled ? {
    eu = { awsRegion = "eu-central-1", instanceId = module.game_eu[0].instance_id, websocketUrl = "wss://${module.game_eu[0].hostname}/ws" }
    na = { awsRegion = "us-east-1", instanceId = module.game_na[0].instance_id, websocketUrl = "wss://${module.game_na[0].hostname}/ws" }
  } : {}
  game_routes = {
    "GET /v1/multiplayer/status"             = false
    "GET /v1/multiplayer/capabilities"       = true
    "POST /v1/multiplayer/start"             = true
    "POST /v1/multiplayer/join-credentials"  = true
    "GET /v1/multiplayer/matches/{match_id}" = true
  }
}

resource "aws_dynamodb_table" "game" {
  provider     = aws.game_na
  for_each     = var.game_servers_enabled ? toset(["control", "tickets", "results"]) : toset([])
  name         = "packetloss-prod-multiplayer-${each.key}"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "pk"
  attribute {
    name = "pk"
    type = "S"
  }
  ttl {
    attribute_name = "expiresAt"
    enabled        = each.key != "results"
  }
  server_side_encryption { enabled = true }
  deletion_protection_enabled = true
  tags                        = local.game_tags
}

resource "aws_s3_bucket" "game_artifacts" {
  provider      = aws.game_na
  count         = var.game_servers_enabled ? 1 : 0
  bucket        = "packetloss-game-artifacts-${data.aws_caller_identity.current.account_id}"
  force_destroy = false
  tags          = local.game_tags
}

resource "aws_s3_bucket_public_access_block" "game_artifacts" {
  provider                = aws.game_na
  count                   = var.game_servers_enabled ? 1 : 0
  bucket                  = aws_s3_bucket.game_artifacts[0].id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "game_artifacts" {
  provider = aws.game_na
  count    = var.game_servers_enabled ? 1 : 0
  bucket   = aws_s3_bucket.game_artifacts[0].id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_versioning" "game_artifacts" {
  provider = aws.game_na
  count    = var.game_servers_enabled ? 1 : 0
  bucket   = aws_s3_bucket.game_artifacts[0].id
  versioning_configuration { status = "Enabled" }
}

data "archive_file" "game_management" {
  count       = var.game_servers_enabled ? 1 : 0
  type        = "zip"
  source_dir  = "${path.module}/../packetloss/dist"
  output_path = "${path.module}/.terraform/game-management.zip"
}

resource "aws_s3_object" "game_management" {
  provider               = aws.game_na
  count                  = var.game_servers_enabled ? 1 : 0
  bucket                 = aws_s3_bucket.game_artifacts[0].id
  key                    = "management/${data.archive_file.game_management[0].output_sha256}.zip"
  source                 = data.archive_file.game_management[0].output_path
  source_hash            = data.archive_file.game_management[0].output_base64sha256
  server_side_encryption = "AES256"
}

module "game_eu" {
  source               = "./modules/game-server"
  count                = var.game_servers_enabled ? 1 : 0
  providers            = { aws = aws.game_eu }
  name                 = "packetloss-game-eu"
  region               = "eu-central-1"
  hostname             = "eu.game.packetloss.${var.domain_name}"
  zone_id              = data.aws_route53_zone.primary.zone_id
  vpc_cidr             = "10.71.0.0/24"
  instance_type        = var.game_server_instance_type
  root_volume_gib      = var.game_server_root_volume_gib
  https_cidrs          = var.game_server_https_cidrs
  certificate_email    = var.game_server_certificate_email
  artifacts_bucket     = aws_s3_bucket.game_artifacts[0].id
  artifacts_bucket_arn = aws_s3_bucket.game_artifacts[0].arn
  management_key       = aws_s3_object.game_management[0].key
  management_sha256    = data.archive_file.game_management[0].output_sha256
  control_table        = aws_dynamodb_table.game["control"].name
  control_table_arn    = aws_dynamodb_table.game["control"].arn
  results_table        = aws_dynamodb_table.game["results"].name
  results_table_arn    = aws_dynamodb_table.game["results"].arn
  tickets_table        = aws_dynamodb_table.game["tickets"].name
  tickets_table_arn    = aws_dynamodb_table.game["tickets"].arn
  site_origin          = "https://${local.packetloss_domains.prod}"
  tags                 = local.game_tags
}

module "game_na" {
  source               = "./modules/game-server"
  count                = var.game_servers_enabled ? 1 : 0
  providers            = { aws = aws.game_na }
  name                 = "packetloss-game-na"
  region               = "us-east-1"
  hostname             = "na.game.packetloss.${var.domain_name}"
  zone_id              = data.aws_route53_zone.primary.zone_id
  vpc_cidr             = "10.72.0.0/24"
  instance_type        = var.game_server_instance_type
  root_volume_gib      = var.game_server_root_volume_gib
  https_cidrs          = var.game_server_https_cidrs
  certificate_email    = var.game_server_certificate_email
  artifacts_bucket     = aws_s3_bucket.game_artifacts[0].id
  artifacts_bucket_arn = aws_s3_bucket.game_artifacts[0].arn
  management_key       = aws_s3_object.game_management[0].key
  management_sha256    = data.archive_file.game_management[0].output_sha256
  control_table        = aws_dynamodb_table.game["control"].name
  control_table_arn    = aws_dynamodb_table.game["control"].arn
  results_table        = aws_dynamodb_table.game["results"].name
  results_table_arn    = aws_dynamodb_table.game["results"].arn
  tickets_table        = aws_dynamodb_table.game["tickets"].name
  tickets_table_arn    = aws_dynamodb_table.game["tickets"].arn
  site_origin          = "https://${local.packetloss_domains.prod}"
  tags                 = local.game_tags
  # EC2 creates running instances. The EU module includes a completed bootstrap
  # association and a one-time stop, so NA cannot begin provisioning concurrently.
  depends_on = [module.game_eu]
}

data "archive_file" "game_control_bootstrap" {
  count       = var.game_servers_enabled ? 1 : 0
  type        = "zip"
  output_path = "${path.module}/.terraform/game-control-bootstrap.zip"
  source {
    filename = "multiplayer.mjs"
    content  = <<-JAVASCRIPT
      export const handler = async () => ({ statusCode: 503, headers: {"content-type": "application/json", "retry-after": "30"}, body: JSON.stringify({code: "SERVICE_UNAVAILABLE", message: "Multiplayer control deployment is pending."}) });
    JAVASCRIPT
  }
}

resource "aws_iam_role" "game_control" {
  count = var.game_servers_enabled ? 1 : 0
  name  = "packetloss-prod-multiplayer-control"
  path  = "/packetloss/"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Principal = { Service = "lambda.amazonaws.com" }, Action = "sts:AssumeRole" }]
  })
  tags = local.game_tags
}

resource "aws_cloudwatch_log_group" "game_control" {
  provider          = aws.game_na
  count             = var.game_servers_enabled ? 1 : 0
  name              = "/aws/lambda/packetloss-prod-multiplayer-control"
  retention_in_days = 7
  tags              = local.game_tags
}

resource "aws_iam_role_policy" "game_control" {
  count = var.game_servers_enabled ? 1 : 0
  role  = aws_iam_role.game_control[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Effect = "Allow", Action = ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:UpdateItem", "dynamodb:DeleteItem"], Resource = [aws_dynamodb_table.game["control"].arn, aws_dynamodb_table.game["tickets"].arn] },
      { Effect = "Allow", Action = ["dynamodb:GetItem"], Resource = [aws_dynamodb_table.game["results"].arn, aws_dynamodb_table.packetloss_api["prod"].arn] },
      { Effect = "Allow", Action = ["ec2:DescribeInstances", "ec2:DescribeInstanceStatus"], Resource = "*" },
      { Effect = "Allow", Action = ["ec2:StartInstances", "ec2:StopInstances"], Resource = [module.game_eu[0].instance_arn, module.game_na[0].instance_arn] },
      { Effect = "Allow", Action = ["ssm:GetCommandInvocation"], Resource = "*" },
      { Effect = "Allow", Action = ["ssm:SendCommand"], Resource = [module.game_eu[0].instance_arn, module.game_na[0].instance_arn, "arn:aws:ssm:eu-central-1::document/AWS-RunShellScript", "arn:aws:ssm:us-east-1::document/AWS-RunShellScript"] },
      { Effect = "Allow", Action = ["logs:CreateLogStream", "logs:PutLogEvents"], Resource = "${aws_cloudwatch_log_group.game_control[0].arn}:*" }
    ]
  })
}

resource "aws_lambda_function" "game_control" {
  provider                       = aws.game_na
  count                          = var.game_servers_enabled ? 1 : 0
  function_name                  = "packetloss-prod-multiplayer-control"
  role                           = aws_iam_role.game_control[0].arn
  runtime                        = "nodejs22.x"
  handler                        = "multiplayer.handler"
  filename                       = data.archive_file.game_control_bootstrap[0].output_path
  source_code_hash               = data.archive_file.game_control_bootstrap[0].output_base64sha256
  memory_size                    = 256
  timeout                        = 30
  reserved_concurrent_executions = 1
  environment {
    variables = {
      CONTROL_TABLE              = aws_dynamodb_table.game["control"].name
      RESULTS_TABLE              = aws_dynamodb_table.game["results"].name
      TICKETS_TABLE              = aws_dynamodb_table.game["tickets"].name
      MULTIPLAYER_CONTROL_REGION = "us-east-1"
      MULTIPLAYER_REGIONS_JSON   = jsonencode(local.game_regions)
      MULTIPLAYER_OWNER_SUB      = length(var.game_server_owner_subjects) == 1 ? one(var.game_server_owner_subjects) : ""
      PROFILE_TABLE_NAME         = aws_dynamodb_table.packetloss_api["prod"].name
      SITE_ORIGIN                = "https://${local.packetloss_domains.prod}"
      IDLE_TIMEOUT_SECONDS       = "1200"
      MAX_UPTIME_SECONDS         = "14400"
    }
  }
  lifecycle {
    ignore_changes = [source_code_hash, handler]
    precondition {
      condition     = length(var.game_server_owner_subjects) == 1 && var.game_server_certificate_email != "" && var.aws_region == "us-east-1"
      error_message = "Enable multiplayer only with one production owner subject, an ACME contact, and the existing us-east-1 account/API region."
    }
  }
  depends_on = [aws_iam_role_policy.game_control, aws_cloudwatch_log_group.game_control]
  tags       = local.game_tags
}

resource "aws_apigatewayv2_integration" "game_control" {
  count                  = var.game_servers_enabled ? 1 : 0
  api_id                 = aws_apigatewayv2_api.packetloss["prod"].id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.game_control[0].invoke_arn
  payload_format_version = "2.0"
  timeout_milliseconds   = 10000
}

resource "aws_apigatewayv2_route" "game_control" {
  for_each           = var.game_servers_enabled ? local.game_routes : {}
  api_id             = aws_apigatewayv2_api.packetloss["prod"].id
  route_key          = each.key
  target             = "integrations/${aws_apigatewayv2_integration.game_control[0].id}"
  authorization_type = each.value ? "JWT" : "NONE"
  authorizer_id      = each.value ? aws_apigatewayv2_authorizer.packetloss["prod"].id : null
}

resource "aws_lambda_permission" "game_control" {
  provider      = aws.game_na
  count         = var.game_servers_enabled ? 1 : 0
  statement_id  = "HttpApi"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.game_control[0].function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.packetloss["prod"].execution_arn}/*/*"
}

resource "aws_iam_role_policy" "game_deploy" {
  count = var.game_servers_enabled ? 1 : 0
  role  = aws_iam_role.packetloss_deploy["prod"].id
  name  = "publish-game-server"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Effect = "Allow", Action = ["s3:GetObject", "s3:PutObject"], Resource = "${aws_s3_bucket.game_artifacts[0].arn}/*" },
      { Effect = "Allow", Action = ["lambda:GetFunctionConfiguration", "lambda:UpdateFunctionCode", "lambda:UpdateFunctionConfiguration"], Resource = aws_lambda_function.game_control[0].arn },
      { Effect = "Allow", Action = ["ec2:DescribeInstances", "ssm:GetCommandInvocation"], Resource = "*" },
      { Effect = "Allow", Action = ["ssm:SendCommand"], Resource = [module.game_eu[0].instance_arn, module.game_na[0].instance_arn, "arn:aws:ssm:eu-central-1::document/AWS-RunShellScript", "arn:aws:ssm:us-east-1::document/AWS-RunShellScript"] }
    ]
  })
}

resource "github_actions_environment_variable" "game" {
  for_each = var.game_servers_enabled ? {
    GAME_ARTIFACTS_BUCKET        = aws_s3_bucket.game_artifacts[0].id
    GAME_CONTROL_LAMBDA_FUNCTION = aws_lambda_function.game_control[0].function_name
    GAME_EU_INSTANCE_ID          = module.game_eu[0].instance_id
    GAME_NA_INSTANCE_ID          = module.game_na[0].instance_id
  } : {}
  repository    = var.packetloss_repository
  environment   = github_repository_environment.packetloss["prod"].environment
  variable_name = each.key
  value         = each.value
}

output "game_servers" {
  description = "Production regional game instances; only the control API may initiate normal starts."
  value = var.game_servers_enabled ? {
    api_url          = "https://${local.packetloss_api_domains.prod}"
    artifacts_bucket = aws_s3_bucket.game_artifacts[0].id
    control_lambda   = aws_lambda_function.game_control[0].function_name
    regions          = local.game_regions
    tables           = { for key, table in aws_dynamodb_table.game : key => table.name }
  } : null
}
