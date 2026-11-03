resource "aws_budgets_budget" "account" {
  for_each = var.budget_limits_usd

  name         = "${each.key}-monthly"
  budget_type  = "COST"
  limit_amount = tostring(each.value)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  cost_filter {
    name   = "LinkedAccount"
    values = [aws_organizations_account.this[each.key].id]
  }

  # 크레딧을 빼고 봅니다. 크레딧을 포함하면 사용량이 0으로 보입니다.
  cost_types {
    include_credit = false
    include_refund = false
  }

  dynamic "notification" {
    for_each = [50, 80, 100]

    content {
      comparison_operator        = "GREATER_THAN"
      threshold                  = notification.value
      threshold_type             = "PERCENTAGE"
      notification_type          = "ACTUAL"
      subscriber_email_addresses = var.budget_emails
    }
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_email_addresses = var.budget_emails
  }
}
