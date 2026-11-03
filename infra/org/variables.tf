variable "account_emails" {
  description = "워크로드 계정별 루트 이메일. 닫은 계정의 이메일은 다시 쓸 수 없습니다"
  type        = map(string)

  validation {
    condition     = toset(keys(var.account_emails)) == toset(["platform", "prod", "sandbox"])
    error_message = "platform, prod, sandbox 세 계정의 이메일을 모두 지정해야 합니다."
  }
}

variable "users" {
  description = "Identity Center 사용자. 키는 username(이름.성, 소문자)"
  type = map(object({
    given_name  = string
    family_name = string
    email       = string
    role        = string # admin | readonly
  }))

  validation {
    condition     = alltrue([for u in values(var.users) : contains(["admin", "readonly"], u.role)])
    error_message = "role에는 admin 또는 readonly만 쓸 수 있습니다."
  }
}

variable "org_admin" {
  description = "관리 계정에 접근하는 조직 관리자의 username"
  type        = string
  default     = "soul.lee"
}

variable "budget_limits_usd" {
  description = "계정별 월 예산(USD). 팀 지원금 50만 원에는 AI 비용도 포함됩니다"
  type        = map(number)
  default = {
    platform = 50
    prod     = 100
    sandbox  = 30
  }
}

variable "budget_emails" {
  description = "예산 알림을 받을 이메일"
  type        = list(string)
}
