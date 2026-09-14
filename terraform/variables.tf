variable "aws_region" {
  description = "AWS region for global-ish supporting resources such as the Terraform lock table."
  type        = string
  default     = "us-east-1"
}

variable "github_owner" {
  description = "GitHub user or organization that owns the repositories."
  type        = string
  default     = "Haki-Malai"
}

variable "infrastructure_repository" {
  description = "Repository that contains this Terraform configuration."
  type        = string
  default     = "infra"
}

variable "domain_name" {
  description = "Primary public domain managed in Route 53."
  type        = string
  default     = "hakimalai.com"
}

variable "required_status_check_context" {
  description = "GitHub check context required before merging to main."
  type        = string
  default     = "Terraform Check"
}
