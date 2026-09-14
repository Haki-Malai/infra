data "aws_caller_identity" "current" {}

locals {
  packetloss_domains = {
    for stage, settings in var.packetloss_stages : stage => "${settings.subdomain}.${var.domain_name}"
  }
  packetloss_tags = { Project = "packetloss", ManagedBy = "terraform" }
}

# CloudFront certificates must be issued in us-east-1 regardless of the S3 region.
provider "aws" {
  alias  = "cloudfront"
  region = "us-east-1"
}

resource "aws_acm_certificate" "packetloss" {
  provider                  = aws.cloudfront
  domain_name               = local.packetloss_domains.prod
  subject_alternative_names = [local.packetloss_domains.dev]
  validation_method         = "DNS"
  tags                      = local.packetloss_tags

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_record" "packetloss_certificate" {
  for_each = {
    for option in aws_acm_certificate.packetloss.domain_validation_options : option.domain_name => option
  }
  zone_id = data.aws_route53_zone.primary.zone_id
  name    = each.value.resource_record_name
  type    = each.value.resource_record_type
  records = [each.value.resource_record_value]
  ttl     = 300
}

resource "aws_acm_certificate_validation" "packetloss" {
  provider                = aws.cloudfront
  certificate_arn         = aws_acm_certificate.packetloss.arn
  validation_record_fqdns = [for record in aws_route53_record.packetloss_certificate : record.fqdn]
}

resource "aws_s3_bucket" "packetloss" {
  for_each      = var.packetloss_stages
  bucket        = "packetloss-${each.key}-${data.aws_caller_identity.current.account_id}-${var.aws_region}"
  force_destroy = false
  tags          = merge(local.packetloss_tags, { Stage = each.key })
}

resource "aws_s3_bucket_public_access_block" "packetloss" {
  for_each                = var.packetloss_stages
  bucket                  = aws_s3_bucket.packetloss[each.key].id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "packetloss" {
  for_each = var.packetloss_stages
  bucket   = aws_s3_bucket.packetloss[each.key].id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "packetloss" {
  for_each = var.packetloss_stages
  bucket   = aws_s3_bucket.packetloss[each.key].id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_versioning" "packetloss" {
  for_each = var.packetloss_stages
  bucket   = aws_s3_bucket.packetloss[each.key].id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "packetloss" {
  for_each = var.packetloss_stages
  bucket   = aws_s3_bucket.packetloss[each.key].id
  rule {
    id     = "bounded-version-history"
    status = "Enabled"
    filter {}
    noncurrent_version_expiration {
      noncurrent_days = 30
    }
    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }
  }
  depends_on = [aws_s3_bucket_versioning.packetloss]
}

resource "aws_cloudfront_origin_access_control" "packetloss" {
  name                              = "packetloss-s3"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

# Rewrite only the known client-side gallery route; missing assets stay errors.
resource "aws_cloudfront_function" "packetloss_dev_route" {
  name    = "packetloss-dev-route"
  runtime = "cloudfront-js-2.0"
  publish = true
  code    = <<-JS
    function handler(event) {
      var request = event.request;
      if (request.uri === '/dev/assets' || request.uri === '/dev/assets/') {
        request.uri = '/index.html';
      }
      return request;
    }
  JS
}

resource "aws_cloudfront_distribution" "packetloss" {
  for_each            = var.packetloss_stages
  enabled             = true
  is_ipv6_enabled     = true
  default_root_object = "index.html"
  aliases             = [local.packetloss_domains[each.key]]
  comment             = "PACKETLOSS ${each.key}"
  price_class         = "PriceClass_100"
  wait_for_deployment = true
  tags                = merge(local.packetloss_tags, { Stage = each.key })

  origin {
    domain_name              = aws_s3_bucket.packetloss[each.key].bucket_regional_domain_name
    origin_id                = "packetloss-${each.key}"
    origin_access_control_id = aws_cloudfront_origin_access_control.packetloss.id
  }

  default_cache_behavior {
    target_origin_id       = "packetloss-${each.key}"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    compress               = true
    min_ttl                = 0
    default_ttl            = 300
    max_ttl                = 31536000
    forwarded_values {
      query_string = false
      cookies {
        forward = "none"
      }
    }
    dynamic "function_association" {
      for_each = each.key == "dev" ? [true] : []
      content {
        event_type   = "viewer-request"
        function_arn = aws_cloudfront_function.packetloss_dev_route.arn
      }
    }
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }
  viewer_certificate {
    acm_certificate_arn      = aws_acm_certificate_validation.packetloss.certificate_arn
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021"
  }
}

resource "aws_s3_bucket_policy" "packetloss" {
  for_each = var.packetloss_stages
  bucket   = aws_s3_bucket.packetloss[each.key].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "CloudFrontReadOnly"
        Effect    = "Allow"
        Principal = { Service = "cloudfront.amazonaws.com" }
        Action    = "s3:GetObject"
        Resource  = "${aws_s3_bucket.packetloss[each.key].arn}/*"
        Condition = { StringEquals = { "AWS:SourceArn" = aws_cloudfront_distribution.packetloss[each.key].arn } }
      },
      {
        Sid       = "RequireTLS"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource  = [aws_s3_bucket.packetloss[each.key].arn, "${aws_s3_bucket.packetloss[each.key].arn}/*"]
        Condition = { Bool = { "aws:SecureTransport" = "false" } }
      }
    ]
  })
  depends_on = [aws_s3_bucket_public_access_block.packetloss]
}
