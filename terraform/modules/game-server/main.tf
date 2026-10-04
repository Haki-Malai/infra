terraform {
  required_providers {
    aws     = { source = "hashicorp/aws" }
    archive = { source = "hashicorp/archive" }
  }
}

data "aws_ssm_parameter" "ami" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64"
}

data "aws_availability_zones" "available" {
  state = "available"
}

resource "aws_vpc" "game" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = merge(var.tags, { Name = var.name })
}

resource "aws_internet_gateway" "game" {
  vpc_id = aws_vpc.game.id
  tags   = var.tags
}

resource "aws_subnet" "game" {
  vpc_id                  = aws_vpc.game.id
  cidr_block              = var.vpc_cidr
  availability_zone       = data.aws_availability_zones.available.names[0]
  map_public_ip_on_launch = true
  tags                    = var.tags
}

resource "aws_route_table" "game" {
  vpc_id = aws_vpc.game.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.game.id
  }
  tags = var.tags
}

resource "aws_route_table_association" "game" {
  subnet_id      = aws_subnet.game.id
  route_table_id = aws_route_table.game.id
}

resource "aws_security_group" "game" {
  name        = var.name
  description = "Direct HTTPS/WSS only; management uses outbound SSM."
  vpc_id      = aws_vpc.game.id
  ingress {
    description = "Authenticated game clients"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = var.https_cidrs
  }
  egress {
    description = "AWS APIs, ACME, updates, and artifact downloads"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = var.tags
}

resource "aws_route53_record" "game" {
  zone_id = var.zone_id
  name    = var.hostname
  type    = "A"
  ttl     = 30
  # A reserved documentation address keeps a stopped, never-started server unreachable.
  # The boot service owns the ephemeral address after provisioning.
  records = ["192.0.2.1"]
  lifecycle { ignore_changes = [records] }
}

resource "aws_iam_role" "game" {
  name = var.name
  path = "/packetloss/"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Principal = { Service = "ec2.amazonaws.com" }, Action = "sts:AssumeRole" }]
  })
  tags = var.tags
}

resource "aws_iam_instance_profile" "game" {
  name = var.name
  role = aws_iam_role.game.name
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.game.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_cloudwatch_log_group" "game" {
  name              = "/packetloss/game/${var.region}"
  retention_in_days = 7
  tags              = var.tags
}

resource "aws_iam_role_policy" "game" {
  name = "runtime"
  role = aws_iam_role.game.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Effect = "Allow", Action = ["s3:GetObject"], Resource = "${var.artifacts_bucket_arn}/*" },
      {
        Effect    = "Allow", Action = ["dynamodb:GetItem", "dynamodb:UpdateItem", "dynamodb:ConditionCheckItem"], Resource = var.control_table_arn
        Condition = { "ForAllValues:StringEquals" = { "dynamodb:LeadingKeys" = ["SERVER"] } }
      },
      { Effect = "Allow", Action = ["dynamodb:GetItem", "dynamodb:UpdateItem"], Resource = var.tickets_table_arn },
      { Effect = "Allow", Action = ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:UpdateItem"], Resource = var.results_table_arn },
      { Effect = "Allow", Action = ["route53:ListHostedZones", "route53:GetChange"], Resource = "*" },
      {
        Effect   = "Allow"
        Action   = ["route53:ChangeResourceRecordSets"]
        Resource = "arn:aws:route53:::hostedzone/${var.zone_id}"
        Condition = { "ForAllValues:StringEquals" = {
          "route53:ChangeResourceRecordSetsNormalizedRecordNames" = [var.hostname, "_acme-challenge.${var.hostname}"]
          "route53:ChangeResourceRecordSetsRecordTypes"           = ["A", "TXT"]
          "route53:ChangeResourceRecordSetsActions"               = ["UPSERT", "DELETE"]
        } }
      },
      { Effect = "Allow", Action = ["logs:CreateLogStream", "logs:PutLogEvents"], Resource = "${aws_cloudwatch_log_group.game.arn}:*" }
    ]
  })
}

locals {
  runtime_env = join("\n", [
    "NODE_ENV=production", "HOST=127.0.0.1", "PORT=8080", "ADMIN_PORT=8081",
    "AWS_REGION=us-east-1", "GAME_REGION=${var.region == "eu-central-1" ? "eu" : "na"}", "SITE_ORIGIN=${var.site_origin}",
    "CONTROL_TABLE=${var.control_table}", "RESULTS_TABLE=${var.results_table}", "TICKETS_TABLE=${var.tickets_table}",
    "GAME_CONTROL_TABLE=${var.control_table}", "GAME_RESULTS_TABLE=${var.results_table}", "GAME_TICKETS_TABLE=${var.tickets_table}",
    "GAME_ALLOWED_ORIGINS=${var.site_origin}", "GAME_SNAPSHOT_HZ=20", "GAME_MAX_UPTIME_MS=14400000", "GAME_IDLE_TIMEOUT_MS=1200000",
    "IDLE_TIMEOUT_SECONDS=1200", "MAX_UPTIME_SECONDS=14400", "MAX_ROOMS=1",
    "GAME_OUTBOX_DIR=/var/lib/packetloss/outbox", "REQUIRE_CLOUD_LEASE=true", ""
  ])
  bootstrap_user_data_base64 = base64gzip(templatefile("${path.module}/bootstrap.sh.tftpl", {
    name               = var.name
    runtime_env        = base64encode(local.runtime_env)
    prepare_script     = base64encode(templatefile("${path.module}/prepare.sh.tftpl", { region = var.region, region_key = var.region == "eu-central-1" ? "eu" : "na", hostname = var.hostname, zone_id = var.zone_id, bucket = var.artifacts_bucket, control_table = var.control_table }))
    deploy_script      = base64encode(file("${path.module}/deploy.sh"))
    artifacts_bucket   = var.artifacts_bucket
    management_key     = var.management_key
    management_sha256  = var.management_sha256
    certificate_config = base64encode(jsonencode({ hostname = var.hostname, zoneId = var.zone_id, email = var.certificate_email }))
    stop_script        = base64encode(file("${path.module}/control-stop.sh"))
    nginx_config       = base64encode(templatefile("${path.module}/nginx.conf.tftpl", { hostname = var.hostname }))
    service            = base64encode(file("${path.module}/packetloss.service"))
    log_config         = base64encode(jsonencode({ logs = { logs_collected = { files = { collect_list = [{ file_path = "/var/log/packetloss/game.log", log_group_name = aws_cloudwatch_log_group.game.name, log_stream_name = "{instance_id}" }] } } } }))
  }))
}

resource "aws_instance" "game" {
  ami                                  = data.aws_ssm_parameter.ami.value
  instance_type                        = var.instance_type
  subnet_id                            = aws_subnet.game.id
  vpc_security_group_ids               = [aws_security_group.game.id]
  iam_instance_profile                 = aws_iam_instance_profile.game.name
  associate_public_ip_address          = true
  disable_api_termination              = true
  instance_initiated_shutdown_behavior = "stop"
  credit_specification { cpu_credits = "standard" }
  metadata_options {
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }
  root_block_device {
    encrypted             = true
    volume_type           = "gp3"
    volume_size           = var.root_volume_gib
    delete_on_termination = false
  }
  user_data_base64 = local.bootstrap_user_data_base64
  tags             = merge(var.tags, { Name = var.name, GameRegion = var.region })
  depends_on       = [aws_route_table_association.game, aws_iam_role_policy.game, aws_route53_record.game]
  lifecycle {
    prevent_destroy = true
    ignore_changes  = [ami, instance_type, user_data_base64]
    precondition {
      condition = nonsensitive(
        floor(length(local.bootstrap_user_data_base64) * 3 / 4) -
        (endswith(local.bootstrap_user_data_base64, "==") ? 2 : endswith(local.bootstrap_user_data_base64, "=") ? 1 : 0) <= 16384
      )
      error_message = "Compressed EC2 user data exceeds the 16 KiB decoded API limit."
    }
  }
}

resource "aws_ssm_association" "bootstrap_complete" {
  name = "AWS-RunShellScript"
  targets {
    key    = "InstanceIds"
    values = [aws_instance.game.id]
  }
  parameters = {
    commands = "timeout 780 bash -c 'until test -f /var/lib/packetloss/bootstrap-ready; do sleep 5; done'"
  }
  wait_for_success_timeout_seconds = 900
}

resource "aws_ec2_instance_state" "initial_stop" {
  instance_id = aws_instance.game.id
  state       = "stopped"
  # Stop once at initial provisioning. Runtime control owns all later transitions.
  lifecycle { ignore_changes = [state] }
  depends_on = [aws_ssm_association.bootstrap_complete]
}

resource "aws_iam_role_policy" "self_stop" {
  name = "stop-own-instance"
  role = aws_iam_role.game.id
  policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Action = ["ec2:StopInstances"], Resource = aws_instance.game.arn }]
  })
}

resource "aws_iam_role" "watchdog" {
  name = "${var.name}-watchdog"
  path = "/packetloss/"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Principal = { Service = "lambda.amazonaws.com" }, Action = "sts:AssumeRole" }]
  })
  tags = var.tags
}

resource "aws_cloudwatch_log_group" "watchdog" {
  name              = "/aws/lambda/${var.name}-watchdog"
  retention_in_days = 7
  tags              = var.tags
}

resource "aws_iam_role_policy" "watchdog" {
  role = aws_iam_role.watchdog.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Effect = "Allow", Action = ["ec2:DescribeInstances"], Resource = "*" },
      { Effect = "Allow", Action = ["ec2:StopInstances"], Resource = aws_instance.game.arn },
      {
        Effect    = "Allow", Action = ["dynamodb:GetItem", "dynamodb:UpdateItem"], Resource = var.control_table_arn
        Condition = { "ForAllValues:StringEquals" = { "dynamodb:LeadingKeys" = ["SERVER"] } }
      },
      { Effect = "Allow", Action = ["logs:CreateLogStream", "logs:PutLogEvents"], Resource = "${aws_cloudwatch_log_group.watchdog.arn}:*" }
    ]
  })
}

data "archive_file" "watchdog" {
  type        = "zip"
  source_file = "${path.root}/../packetloss/dist/watchdog.mjs"
  output_path = "${path.root}/.terraform/${var.name}-watchdog.zip"
}

resource "aws_lambda_function" "watchdog" {
  function_name                  = "${var.name}-watchdog"
  role                           = aws_iam_role.watchdog.arn
  runtime                        = "nodejs22.x"
  handler                        = "watchdog.handler"
  filename                       = data.archive_file.watchdog.output_path
  source_code_hash               = data.archive_file.watchdog.output_base64sha256
  timeout                        = 30
  memory_size                    = 128
  reserved_concurrent_executions = 1
  environment {
    variables = {
      INSTANCE_ID        = aws_instance.game.id
      MAX_UPTIME_SECONDS = "14400"
      CONTROL_TABLE      = var.control_table
      GAME_REGION        = var.region == "eu-central-1" ? "eu" : "na"
    }
  }
  tags       = var.tags
  depends_on = [aws_cloudwatch_log_group.watchdog, aws_iam_role_policy.watchdog]
}

resource "aws_cloudwatch_event_rule" "watchdog" {
  name                = "${var.name}-watchdog"
  schedule_expression = "rate(1 minute)"
  tags                = var.tags
}

resource "aws_cloudwatch_event_target" "watchdog" {
  rule = aws_cloudwatch_event_rule.watchdog.name
  arn  = aws_lambda_function.watchdog.arn
}

resource "aws_lambda_permission" "watchdog" {
  statement_id  = "ScheduledWatchdog"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.watchdog.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.watchdog.arn
}
