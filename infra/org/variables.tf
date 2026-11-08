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
