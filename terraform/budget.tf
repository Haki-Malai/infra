variable "budget_alert_email" {
  description = "Confirmed recipient for monthly budget alerts; supply privately through TF_VAR_budget_alert_email."
  type        = string
  sensitive   = true
  validation {
    condition     = can(regex("^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", var.budget_alert_email))
    error_message = "Provide a valid budget alert email address."
  }
}

variable "budget_scope" {
  description = "Defaults to the confirmed whole-account budget; packetloss restricts costs to Project=packetloss."
  type        = string
  default     = "account"
  validation {
    condition     = contains(["account", "packetloss"], var.budget_scope)
    error_message = "Budget scope must be account or packetloss."
  }
}

variable "monthly_budget_usd" {
  description = "Monthly cost budget in USD. This is an alerting threshold, not an enforced spending cap."
  type        = number
  default     = 5
  validation {
    condition     = var.monthly_budget_usd > 0
    error_message = "The monthly budget must be positive."
  }
}

variable "budget_alert_usd" {
  description = "Early actual-spend notification threshold in USD."
  type        = number
  default     = 2.5
  validation {
    condition     = var.budget_alert_usd > 0
    error_message = "The early alert threshold must be positive."
  }
}

# For project-only budgets, AWS must first discover this tag in billing (up to 24 hours).
resource "aws_ce_cost_allocation_tag" "packetloss" {
  count   = var.budget_scope == "packetloss" ? 1 : 0
  tag_key = "Project"
  status  = "Active"
}

resource "aws_budgets_budget" "monthly" {
  name         = "hm-monthly"
  budget_type  = "COST"
  limit_amount = tostring(var.monthly_budget_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  # Keep an explicit filter even for account scope so removing the project filter
  # does not retain the provider's previously computed filter configuration.
  cost_filter {
    name   = "LinkedAccount"
    values = [data.aws_caller_identity.current.account_id]
  }

  dynamic "cost_filter" {
    for_each = var.budget_scope == "packetloss" ? [true] : []
    content {
      name   = "TagKeyValue"
      values = ["Project$packetloss"]
    }
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    notification_type          = "ACTUAL"
    threshold_type             = "ABSOLUTE_VALUE"
    threshold                  = var.budget_alert_usd
    subscriber_email_addresses = [var.budget_alert_email]
  }
  notification {
    comparison_operator        = "GREATER_THAN"
    notification_type          = "ACTUAL"
    threshold_type             = "ABSOLUTE_VALUE"
    threshold                  = var.monthly_budget_usd
    subscriber_email_addresses = [var.budget_alert_email]
  }
  notification {
    comparison_operator        = "GREATER_THAN"
    notification_type          = "FORECASTED"
    threshold_type             = "ABSOLUTE_VALUE"
    threshold                  = var.monthly_budget_usd
    subscriber_email_addresses = [var.budget_alert_email]
  }

  lifecycle {
    precondition {
      condition     = var.budget_alert_usd < var.monthly_budget_usd
      error_message = "The early alert must be below the monthly budget."
    }
  }
  depends_on = [aws_ce_cost_allocation_tag.packetloss]
}
