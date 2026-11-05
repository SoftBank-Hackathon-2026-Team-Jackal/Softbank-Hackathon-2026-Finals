variable "billing_account" {
  description = "결제 계정 ID (예: 01ABCD-234567-89EFGH)"
  type        = string
}

variable "budget_currency" {
  description = "결제 계정의 통화. 결제 계정과 다르면 예산 생성이 실패합니다"
  type        = string
  default     = "KRW"
}

variable "budget_amounts" {
  description = "프로젝트별 월 예산 (budget_currency 단위)"
  type        = map(number)
  default = {
    prod    = 100000
    sandbox = 30000
  }
}

variable "team_members" {
  description = "프로젝트 Editor와 Project IAM Admin을 받을 팀원. 형식은 user:<이메일>"
  type        = list(string)
}
