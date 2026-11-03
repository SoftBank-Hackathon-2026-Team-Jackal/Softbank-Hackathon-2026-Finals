locals {
  management_account_id = "813360232874"
  region                = "ap-northeast-2"

  sso_instance_arn  = tolist(data.aws_ssoadmin_instances.this.arns)[0]
  identity_store_id = tolist(data.aws_ssoadmin_instances.this.identity_store_ids)[0]

  # OU 이름 = 계정 이름. env 하나가 계정 하나에 대응합니다 (notes/cloud-structure.md 2절).
  workloads = toset(["platform", "prod", "sandbox"])
}

data "aws_ssoadmin_instances" "this" {}
