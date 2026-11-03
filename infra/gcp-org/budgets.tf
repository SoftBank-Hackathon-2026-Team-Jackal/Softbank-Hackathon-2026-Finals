# 기본 수신자(결제 계정 관리자와 사용자)에게 이메일로 알립니다.
resource "google_billing_budget" "this" {
  provider = google.quota
  for_each = var.budget_amounts

  billing_account = var.billing_account
  display_name    = "${each.key}-monthly"

  budget_filter {
    projects               = ["projects/${google_project.this[each.key].number}"]
    credit_types_treatment = "EXCLUDE_ALL_CREDITS"
  }

  amount {
    specified_amount {
      currency_code = var.budget_currency
      units         = tostring(each.value)
    }
  }

  dynamic "threshold_rules" {
    for_each = [0.5, 0.8, 1.0]

    content {
      threshold_percent = threshold_rules.value
    }
  }

  threshold_rules {
    threshold_percent = 1.0
    spend_basis       = "FORECASTED_SPEND"
  }

  depends_on = [google_project_service.this]
}
