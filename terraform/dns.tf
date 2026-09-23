data "aws_route53_zone" "primary" {
  name         = "${var.domain_name}."
  private_zone = false
}

resource "aws_route53_record" "apex_a" {
  zone_id = data.aws_route53_zone.primary.zone_id
  name    = var.domain_name
  type    = "A"
  ttl     = 300
  records = local.github_pages_apex_ipv4
}

resource "aws_route53_record" "apex_aaaa" {
  zone_id = data.aws_route53_zone.primary.zone_id
  name    = var.domain_name
  type    = "AAAA"
  ttl     = 300
  records = local.github_pages_apex_ipv6
}

resource "aws_route53_record" "qr_a" {
  zone_id = data.aws_route53_zone.primary.zone_id
  name    = local.github_pages_subdomains.qr
  type    = "A"
  ttl     = 300
  records = local.github_pages_apex_ipv4
}

resource "aws_route53_record" "qr_aaaa" {
  zone_id = data.aws_route53_zone.primary.zone_id
  name    = local.github_pages_subdomains.qr
  type    = "AAAA"
  ttl     = 300
  records = local.github_pages_apex_ipv6
}

resource "aws_route53_record" "packetloss_a" {
  zone_id = data.aws_route53_zone.primary.zone_id
  name    = local.packetloss_domains.prod
  type    = "A"
  alias {
    name                   = aws_cloudfront_distribution.packetloss["prod"].domain_name
    zone_id                = aws_cloudfront_distribution.packetloss["prod"].hosted_zone_id
    evaluate_target_health = false
  }
}

resource "aws_route53_record" "packetloss_aaaa" {
  zone_id = data.aws_route53_zone.primary.zone_id
  name    = local.packetloss_domains.prod
  type    = "AAAA"
  alias {
    name                   = aws_cloudfront_distribution.packetloss["prod"].domain_name
    zone_id                = aws_cloudfront_distribution.packetloss["prod"].hosted_zone_id
    evaluate_target_health = false
  }
}

resource "aws_route53_record" "packetloss_dev" {
  for_each = toset(["A", "AAAA"])
  zone_id  = data.aws_route53_zone.primary.zone_id
  name     = local.packetloss_domains.dev
  type     = each.key
  alias {
    name                   = aws_cloudfront_distribution.packetloss["dev"].domain_name
    zone_id                = aws_cloudfront_distribution.packetloss["dev"].hosted_zone_id
    evaluate_target_health = false
  }
}
