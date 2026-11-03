terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

# 관리 계정 자격 증명으로 실행합니다. 처음에는 AWS_PROFILE=root-bootstrap, SSO 구성 뒤에는 AWS_PROFILE=mgmt
provider "aws" {
  region = local.region

  allowed_account_ids = [local.management_account_id]

  default_tags {
    tags = {
      Project   = "sbh26"
      ManagedBy = "terraform"
      Stack     = "org"
    }
  }
}
