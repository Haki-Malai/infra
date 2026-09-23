locals {
  packetloss_api_domains = {
    for stage, settings in var.packetloss_stages : stage => "api.${settings.subdomain}.${var.domain_name}"
  }
  packetloss_api_routes = {
    "GET /health"                       = false
    "POST /v1/auth/signup"              = false
    "POST /v1/auth/confirm"             = false
    "POST /v1/auth/resend-confirmation" = false
    "POST /v1/auth/login"               = false
    "POST /v1/auth/refresh"             = false
    "POST /v1/auth/logout"              = false
    "POST /v1/auth/forgot-password"     = false
    "POST /v1/auth/reset-password"      = false
    "GET /v1/me"                        = true
    "PATCH /v1/me"                      = true
    "GET /v1/me/records"                = true
    "PUT /v1/me/records"                = true
    "DELETE /v1/me/records"             = true
  }
  packetloss_api_stage_routes = merge([
    for stage in keys(var.packetloss_stages) : {
      for route, authenticated in local.packetloss_api_routes : "${stage}/${route}" => {
        stage         = stage
        route         = route
        authenticated = authenticated
      }
    }
  ]...)
}

data "archive_file" "packetloss_api_bootstrap" {
  type        = "zip"
  output_path = "${path.module}/.terraform/packetloss-api-bootstrap.zip"

  source {
    filename = "packetloss_api/__init__.py"
    content  = ""
  }

  source {
    filename = "packetloss_api/lambda_handler.py"
    content  = <<-PYTHON
      def handler(_event, _context):
          return {
              "statusCode": 503,
              "headers": {"content-type": "application/json", "retry-after": "30"},
              "body": '{"code":"SERVICE_UNAVAILABLE","message":"API deployment is pending."}',
          }
    PYTHON
  }
}

resource "aws_dynamodb_table" "packetloss_api" {
  for_each       = var.packetloss_stages
  name           = "packetloss-${each.key}-api"
  billing_mode   = "PROVISIONED"
  read_capacity  = each.value.api_read_capacity
  write_capacity = each.value.api_write_capacity
  hash_key       = "pk"
  range_key      = "sk"

  attribute {
    name = "pk"
    type = "S"
  }

  attribute {
    name = "sk"
    type = "S"
  }

  ttl {
    attribute_name = "expires_at"
    enabled        = true
  }

  server_side_encryption {
    enabled = true
  }

  tags = merge(local.packetloss_tags, { Stage = each.key })
}

resource "aws_cognito_user_pool" "packetloss" {
  for_each                 = var.packetloss_stages
  name                     = "packetloss-${each.key}"
  user_pool_tier           = "LITE"
  username_attributes      = ["email"]
  auto_verified_attributes = ["email"]
  mfa_configuration        = "OFF"

  username_configuration {
    case_sensitive = false
  }

  password_policy {
    minimum_length                   = 12
    require_lowercase                = true
    require_numbers                  = true
    require_symbols                  = false
    require_uppercase                = true
    temporary_password_validity_days = 7
  }

  account_recovery_setting {
    recovery_mechanism {
      name     = "verified_email"
      priority = 1
    }
  }

  schema {
    attribute_data_type = "String"
    mutable             = true
    name                = "email"
    required            = true
    string_attribute_constraints {
      min_length = 3
      max_length = 254
    }
  }

  user_attribute_update_settings {
    attributes_require_verification_before_update = ["email"]
  }

  verification_message_template {
    default_email_option = "CONFIRM_WITH_CODE"
  }

  tags = merge(local.packetloss_tags, { Stage = each.key })
}

resource "aws_cognito_user_pool_client" "packetloss_api" {
  for_each                             = var.packetloss_stages
  name                                 = "packetloss-${each.key}-api"
  user_pool_id                         = aws_cognito_user_pool.packetloss[each.key].id
  generate_secret                      = true
  prevent_user_existence_errors        = "ENABLED"
  enable_token_revocation              = true
  explicit_auth_flows                  = ["ALLOW_USER_PASSWORD_AUTH", "ALLOW_REFRESH_TOKEN_AUTH"]
  access_token_validity                = 60
  id_token_validity                    = 60
  refresh_token_validity               = 30
  auth_session_validity                = 3
  allowed_oauth_flows_user_pool_client = false

  token_validity_units {
    access_token  = "minutes"
    id_token      = "minutes"
    refresh_token = "days"
  }
}

resource "aws_iam_role" "packetloss_api" {
  for_each = var.packetloss_stages
  name     = "packetloss-${each.key}-api"
  path     = "/packetloss/"
  tags     = merge(local.packetloss_tags, { Stage = each.key })
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "packetloss_api" {
  for_each = var.packetloss_stages
  name     = "api-runtime"
  role     = aws_iam_role.packetloss_api[each.key].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        # Transactions require the permissions for their underlying item operations.
        Action = [
          "dynamodb:BatchWriteItem",
          "dynamodb:GetItem",
          "dynamodb:PutItem",
          "dynamodb:UpdateItem",
          "dynamodb:DeleteItem",
          "dynamodb:Query",
        ]
        Resource = aws_dynamodb_table.packetloss_api[each.key].arn
      },
      {
        Effect = "Allow"
        Action = [
          "cognito-idp:ConfirmForgotPassword",
          "cognito-idp:ConfirmSignUp",
          "cognito-idp:ForgotPassword",
          "cognito-idp:InitiateAuth",
          "cognito-idp:RevokeToken",
          "cognito-idp:SignUp"
        ]
        Resource = aws_cognito_user_pool.packetloss[each.key].arn
      },
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "${aws_cloudwatch_log_group.packetloss_api[each.key].arn}:*"
      }
    ]
  })
}

resource "aws_cloudwatch_log_group" "packetloss_api" {
  for_each          = var.packetloss_stages
  name              = "/aws/lambda/packetloss-${each.key}-api"
  retention_in_days = 7
  tags              = merge(local.packetloss_tags, { Stage = each.key })
}

resource "aws_lambda_function" "packetloss_api" {
  for_each         = var.packetloss_stages
  function_name    = "packetloss-${each.key}-api"
  role             = aws_iam_role.packetloss_api[each.key].arn
  runtime          = "python3.12"
  architectures    = ["x86_64"]
  handler          = "packetloss_api.lambda_handler.handler"
  filename         = data.archive_file.packetloss_api_bootstrap.output_path
  source_code_hash = data.archive_file.packetloss_api_bootstrap.output_base64sha256
  memory_size      = 256
  timeout          = 10

  reserved_concurrent_executions = each.value.api_lambda_concurrency

  environment {
    variables = {
      STAGE                   = each.key
      TABLE_NAME              = aws_dynamodb_table.packetloss_api[each.key].name
      USER_POOL_ID            = aws_cognito_user_pool.packetloss[each.key].id
      USER_POOL_CLIENT_ID     = aws_cognito_user_pool_client.packetloss_api[each.key].id
      USER_POOL_CLIENT_SECRET = aws_cognito_user_pool_client.packetloss_api[each.key].client_secret
      SITE_ORIGIN             = "https://${local.packetloss_domains[each.key]}"
      REFRESH_COOKIE_NAME     = "packetloss_${each.key}_refresh"
      SIGNUP_DAILY_LIMIT      = tostring(each.value.api_signup_daily_limit)
      SIGNUP_ACCOUNT_LIMIT    = tostring(each.value.api_signup_account_limit)
      MAX_PAYLOAD_BYTES       = "16384"
    }
  }

  tags       = merge(local.packetloss_tags, { Stage = each.key })
  depends_on = [aws_cloudwatch_log_group.packetloss_api]

  lifecycle {
    ignore_changes = [source_code_hash]
  }
}

resource "aws_apigatewayv2_api" "packetloss" {
  for_each      = var.packetloss_stages
  name          = "packetloss-${each.key}"
  protocol_type = "HTTP"

  cors_configuration {
    allow_credentials = true
    allow_headers     = ["authorization", "content-type"]
    expose_headers    = ["Retry-After"]
    allow_methods     = ["GET", "POST", "PATCH", "PUT", "DELETE", "OPTIONS"]
    allow_origins     = ["https://${local.packetloss_domains[each.key]}"]
    max_age           = 3600
  }

  tags = merge(local.packetloss_tags, { Stage = each.key })
}

resource "aws_apigatewayv2_integration" "packetloss_api" {
  for_each               = var.packetloss_stages
  api_id                 = aws_apigatewayv2_api.packetloss[each.key].id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.packetloss_api[each.key].invoke_arn
  integration_method     = "POST"
  payload_format_version = "2.0"
  timeout_milliseconds   = 10000
}

resource "aws_apigatewayv2_authorizer" "packetloss" {
  for_each         = var.packetloss_stages
  api_id           = aws_apigatewayv2_api.packetloss[each.key].id
  name             = "packetloss-${each.key}-cognito"
  authorizer_type  = "JWT"
  identity_sources = ["$request.header.Authorization"]

  jwt_configuration {
    audience = [aws_cognito_user_pool_client.packetloss_api[each.key].id]
    issuer   = "https://cognito-idp.${var.aws_region}.amazonaws.com/${aws_cognito_user_pool.packetloss[each.key].id}"
  }
}

resource "aws_apigatewayv2_route" "packetloss_api" {
  for_each           = local.packetloss_api_stage_routes
  api_id             = aws_apigatewayv2_api.packetloss[each.value.stage].id
  route_key          = each.value.route
  target             = "integrations/${aws_apigatewayv2_integration.packetloss_api[each.value.stage].id}"
  authorization_type = each.value.authenticated ? "JWT" : "NONE"
  authorizer_id      = each.value.authenticated ? aws_apigatewayv2_authorizer.packetloss[each.value.stage].id : null
}

resource "aws_apigatewayv2_stage" "packetloss" {
  for_each    = var.packetloss_stages
  api_id      = aws_apigatewayv2_api.packetloss[each.key].id
  name        = "$default"
  auto_deploy = true

  default_route_settings {
    throttling_rate_limit  = each.value.api_throttle_rate
    throttling_burst_limit = each.value.api_throttle_burst
  }

  dynamic "route_settings" {
    for_each = toset([
      for route in keys(local.packetloss_api_routes) : route
      if startswith(route, "POST /v1/auth/")
    ])
    content {
      route_key = route_settings.value
      throttling_rate_limit = contains(["POST /v1/auth/signup", "POST /v1/auth/resend-confirmation"], route_settings.value) ? 1 : min(
        each.value.api_throttle_rate,
        5,
      )
      throttling_burst_limit = contains(["POST /v1/auth/signup", "POST /v1/auth/resend-confirmation"], route_settings.value) ? 2 : min(
        each.value.api_throttle_burst,
        10,
      )
    }
  }

  tags = merge(local.packetloss_tags, { Stage = each.key })
}

resource "aws_lambda_permission" "packetloss_api_gateway" {
  for_each      = var.packetloss_stages
  statement_id  = "AllowApiGateway"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.packetloss_api[each.key].function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.packetloss[each.key].execution_arn}/*/*"
}

resource "aws_acm_certificate" "packetloss_api" {
  domain_name               = local.packetloss_api_domains.prod
  subject_alternative_names = [local.packetloss_api_domains.dev]
  validation_method         = "DNS"
  tags                      = local.packetloss_tags

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_record" "packetloss_api_certificate" {
  for_each = {
    for option in aws_acm_certificate.packetloss_api.domain_validation_options : option.domain_name => option
  }
  zone_id = data.aws_route53_zone.primary.zone_id
  name    = each.value.resource_record_name
  type    = each.value.resource_record_type
  records = [each.value.resource_record_value]
  ttl     = 300
}

resource "aws_acm_certificate_validation" "packetloss_api" {
  certificate_arn         = aws_acm_certificate.packetloss_api.arn
  validation_record_fqdns = [for record in aws_route53_record.packetloss_api_certificate : record.fqdn]
}

resource "aws_apigatewayv2_domain_name" "packetloss" {
  for_each    = var.packetloss_stages
  domain_name = local.packetloss_api_domains[each.key]

  domain_name_configuration {
    certificate_arn = aws_acm_certificate_validation.packetloss_api.certificate_arn
    endpoint_type   = "REGIONAL"
    security_policy = "TLS_1_2"
  }

  tags = merge(local.packetloss_tags, { Stage = each.key })
}

resource "aws_apigatewayv2_api_mapping" "packetloss" {
  for_each    = var.packetloss_stages
  api_id      = aws_apigatewayv2_api.packetloss[each.key].id
  domain_name = aws_apigatewayv2_domain_name.packetloss[each.key].id
  stage       = aws_apigatewayv2_stage.packetloss[each.key].id
}

resource "aws_route53_record" "packetloss_api" {
  for_each = var.packetloss_stages
  zone_id  = data.aws_route53_zone.primary.zone_id
  name     = local.packetloss_api_domains[each.key]
  type     = "A"

  alias {
    name                   = aws_apigatewayv2_domain_name.packetloss[each.key].domain_name_configuration[0].target_domain_name
    zone_id                = aws_apigatewayv2_domain_name.packetloss[each.key].domain_name_configuration[0].hosted_zone_id
    evaluate_target_health = false
  }
}

resource "aws_sns_topic" "packetloss_api_alerts" {
  name = "packetloss-api-alerts"
  tags = local.packetloss_tags
}

resource "aws_sns_topic_subscription" "packetloss_api_alerts_email" {
  topic_arn = aws_sns_topic.packetloss_api_alerts.arn
  protocol  = "email"
  endpoint  = var.budget_alert_email
}

resource "aws_cloudwatch_metric_alarm" "packetloss_api_errors" {
  for_each            = var.packetloss_stages
  alarm_name          = "packetloss-${each.key}-api-errors"
  alarm_description   = "PACKETLOSS ${each.key} API returned Lambda errors."
  namespace           = "AWS/Lambda"
  metric_name         = "Errors"
  dimensions          = { FunctionName = aws_lambda_function.packetloss_api[each.key].function_name }
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  period              = 300
  statistic           = "Sum"
  threshold           = 1
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.packetloss_api_alerts.arn]
  tags                = merge(local.packetloss_tags, { Stage = each.key })
}

resource "aws_cloudwatch_metric_alarm" "packetloss_api_lambda_throttles" {
  for_each            = var.packetloss_stages
  alarm_name          = "packetloss-${each.key}-api-lambda-throttles"
  alarm_description   = "PACKETLOSS ${each.key} API reached its fixed Lambda concurrency."
  namespace           = "AWS/Lambda"
  metric_name         = "Throttles"
  dimensions          = { FunctionName = aws_lambda_function.packetloss_api[each.key].function_name }
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  period              = 300
  statistic           = "Sum"
  threshold           = 1
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.packetloss_api_alerts.arn]
  tags                = merge(local.packetloss_tags, { Stage = each.key })
}

resource "aws_cloudwatch_metric_alarm" "packetloss_api_read_throttles" {
  for_each            = var.packetloss_stages
  alarm_name          = "packetloss-${each.key}-api-read-throttles"
  alarm_description   = "PACKETLOSS ${each.key} table reached fixed read capacity."
  namespace           = "AWS/DynamoDB"
  metric_name         = "ReadThrottleEvents"
  dimensions          = { TableName = aws_dynamodb_table.packetloss_api[each.key].name }
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  period              = 300
  statistic           = "Sum"
  threshold           = 1
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.packetloss_api_alerts.arn]
  tags                = merge(local.packetloss_tags, { Stage = each.key })
}

resource "aws_cloudwatch_metric_alarm" "packetloss_api_write_throttles" {
  for_each            = var.packetloss_stages
  alarm_name          = "packetloss-${each.key}-api-write-throttles"
  alarm_description   = "PACKETLOSS ${each.key} table reached fixed write capacity."
  namespace           = "AWS/DynamoDB"
  metric_name         = "WriteThrottleEvents"
  dimensions          = { TableName = aws_dynamodb_table.packetloss_api[each.key].name }
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  period              = 300
  statistic           = "Sum"
  threshold           = 1
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.packetloss_api_alerts.arn]
  tags                = merge(local.packetloss_tags, { Stage = each.key })
}

resource "aws_cloudwatch_metric_alarm" "packetloss_api_request_volume" {
  for_each            = var.packetloss_stages
  alarm_name          = "packetloss-${each.key}-api-request-volume"
  alarm_description   = "PACKETLOSS ${each.key} API received unusual hourly request volume."
  namespace           = "AWS/ApiGateway"
  metric_name         = "Count"
  dimensions          = { ApiId = aws_apigatewayv2_api.packetloss[each.key].id, Stage = "$default" }
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  period              = 3600
  statistic           = "Sum"
  threshold           = each.key == "prod" ? 10000 : 2000
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.packetloss_api_alerts.arn]
  tags                = merge(local.packetloss_tags, { Stage = each.key })
}
