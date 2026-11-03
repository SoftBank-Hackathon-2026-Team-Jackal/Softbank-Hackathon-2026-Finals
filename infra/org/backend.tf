# 이 스택의 state는 관리 계정의 S3 버킷(state.tf)에 둡니다.
# 처음부터 다시 만들 때는 버킷이 없으므로 아래 블록을 주석으로 처리하고 로컬 state로 apply한 뒤,
# 주석을 풀고 `terraform init -migrate-state`로 옮깁니다.

terraform {
  backend "s3" {
    bucket       = "sbh26-org-tfstate-813360232874"
    key          = "org/terraform.tfstate"
    region       = "ap-northeast-2"
    encrypt      = true
    use_lockfile = true
  }
}
