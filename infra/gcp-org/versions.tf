# 평소 작업 계정(alus20x@gmail.com)으로 실행합니다. 조직 역할은 bootstrap/에서 부여했습니다.
#
# 실행:
#   export GOOGLE_OAUTH_ACCESS_TOKEN=$(gcloud auth print-access-token --account=alus20x@gmail.com)
#   AWS_PROFILE=mgmt terraform apply

terraform {
  required_version = ">= 1.10"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 7.0"
    }
  }

  # state는 AWS 관리 계정의 org state 버킷에 함께 둡니다 (notes/cloud-structure.md: state는 한 곳에서 관리).
  backend "s3" {
    bucket       = "sbh26-org-tfstate-813360232874"
    key          = "gcp-org/terraform.tfstate"
    region       = "ap-northeast-2"
    profile      = "mgmt"
    encrypt      = true
    use_lockfile = true
  }
}

provider "google" {
  region = local.region

  default_labels = {
    project    = "sbh26"
    managed-by = "terraform"
    stack      = "gcp-org"
  }
}

# Billing Budgets API는 사용자 자격 증명으로 호출할 때 할당량 프로젝트가 필요합니다.
provider "google" {
  alias                 = "quota"
  region                = local.region
  billing_project       = local.quota_project
  user_project_override = true
}
