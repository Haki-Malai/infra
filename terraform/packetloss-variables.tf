variable "packetloss_repository" {
  description = "Application repository deployed to the PACKETLOSS environments."
  type        = string
  default     = "PACKETLOSS"
}

variable "packetloss_stages" {
  description = "Branch, hostname, and public build settings for each deployment stage."
  type = map(object({
    branch                   = string
    subdomain                = string
    build_mode               = string
    vite_game_env            = string
    api_read_capacity        = number
    api_write_capacity       = number
    api_lambda_concurrency   = number
    api_signup_daily_limit   = number
    api_signup_account_limit = number
    api_throttle_rate        = number
    api_throttle_burst       = number
  }))
  default = {
    dev = {
      branch                   = "dev"
      subdomain                = "dev.packetloss"
      build_mode               = "development"
      vite_game_env            = "DEFAULT"
      api_read_capacity        = 1
      api_write_capacity       = 1
      api_lambda_concurrency   = 1
      api_signup_daily_limit   = 5
      api_signup_account_limit = 100
      api_throttle_rate        = 5
      api_throttle_burst       = 10
    }
    prod = {
      branch                   = "main"
      subdomain                = "packetloss"
      build_mode               = "production"
      vite_game_env            = "DEFAULT"
      api_read_capacity        = 4
      api_write_capacity       = 4
      api_lambda_concurrency   = 4
      api_signup_daily_limit   = 30
      api_signup_account_limit = 1000
      api_throttle_rate        = 20
      api_throttle_burst       = 40
    }
  }

  validation {
    condition = (
      toset(keys(var.packetloss_stages)) == toset(["dev", "prod"]) &&
      try(var.packetloss_stages.dev.branch == "dev" && var.packetloss_stages.dev.build_mode == "development", false) &&
      try(var.packetloss_stages.prod.branch == "main" && var.packetloss_stages.prod.build_mode == "production", false) &&
      alltrue([for stage in var.packetloss_stages : contains(["DEFAULT", "DEMO"], stage.vite_game_env)])
      && alltrue([for stage in var.packetloss_stages : stage.api_read_capacity > 0 && stage.api_write_capacity > 0])
      && alltrue([for stage in var.packetloss_stages : stage.api_lambda_concurrency > 0])
      && alltrue([for stage in var.packetloss_stages : stage.api_signup_daily_limit > 0 && stage.api_signup_account_limit >= stage.api_signup_daily_limit])
      && alltrue([for stage in var.packetloss_stages : stage.api_throttle_rate > 0 && stage.api_throttle_burst > 0])
    )
    error_message = "Define the fixed dev/prod branch, build, game, API capacity, signup, and throttle settings."
  }
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
