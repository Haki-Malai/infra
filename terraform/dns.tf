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

resource "aws_route53_record" "packetloss_cname" {
  zone_id = data.aws_route53_zone.primary.zone_id
  name    = local.github_pages_subdomains.packetloss
  type    = "CNAME"
  ttl     = 300
  records = ["haki-malai.github.io"]
}
