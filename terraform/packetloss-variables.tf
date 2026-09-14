variable "packetloss_repository" {
  description = "Application repository deployed to the PACKETLOSS environments."
  type        = string
  default     = "PACKETLOSS"
}

variable "packetloss_stages" {
  description = "Branch, hostname, and public build settings for each deployment stage."
  type = map(object({
    branch        = string
    subdomain     = string
    build_mode    = string
    vite_game_env = string
  }))
  default = {
    dev = {
      branch        = "dev"
      subdomain     = "dev.packetloss"
      build_mode    = "development"
      vite_game_env = "DEFAULT"
    }
    prod = {
      branch        = "main"
      subdomain     = "packetloss"
      build_mode    = "production"
      vite_game_env = "DEFAULT"
    }
  }

  validation {
    condition = (
      toset(keys(var.packetloss_stages)) == toset(["dev", "prod"]) &&
      try(var.packetloss_stages.dev.branch == "dev" && var.packetloss_stages.dev.build_mode == "development", false) &&
      try(var.packetloss_stages.prod.branch == "main" && var.packetloss_stages.prod.build_mode == "production", false) &&
      alltrue([for stage in var.packetloss_stages : contains(["DEFAULT", "DEMO"], stage.vite_game_env)])
    )
    error_message = "Define dev/development on dev and prod/production on main, with DEFAULT or DEMO maps."
  }
}

variable "packetloss_production_dns_enabled" {
  description = "Switch production DNS to CloudFront only after both sites have been uploaded and checked."
  type        = bool
  default     = false
}

variable "github_oidc_provider_arn" {
  description = "Existing GitHub OIDC provider ARN, or empty to create it; inspect IAM before the first apply."
  type        = string
  default     = ""
  validation {
    condition     = var.github_oidc_provider_arn == "" || can(regex("^arn:aws:iam::[0-9]{12}:oidc-provider/token\\.actions\\.githubusercontent\\.com$", var.github_oidc_provider_arn))
    error_message = "Provide GitHub's existing OIDC provider ARN or an empty string."
  }
}
