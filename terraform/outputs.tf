output "route53_zone_id" {
  description = "Route 53 hosted zone ID for the primary domain."
  value       = data.aws_route53_zone.primary.zone_id
}

output "managed_domains" {
  description = "Domains managed by this Terraform root."
  value = {
    apex = var.domain_name
    subdomains = merge(local.github_pages_subdomains, {
      packetloss     = local.packetloss_domains.prod
      packetloss_dev = local.packetloss_domains.dev
    })
  }
}

output "packetloss_environments" {
  description = "Deployment targets and CloudFront hosts for pre-cutover verification."
  value = {
    for stage, settings in var.packetloss_stages : stage => {
      branch                     = settings.branch
      url                        = "https://${local.packetloss_domains[stage]}"
      bucket                     = aws_s3_bucket.packetloss[stage].id
      cloudfront_domain          = aws_cloudfront_distribution.packetloss[stage].domain_name
      cloudfront_distribution_id = aws_cloudfront_distribution.packetloss[stage].id
      deploy_role_arn            = aws_iam_role.packetloss_deploy[stage].arn
    }
  }
}
