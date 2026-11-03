# CDC PoC 2단계: AWS prod(env-a) ↔ GCP sbh26-prod(env-b)를 WireGuard로 잇고 1단계 스크립트를 그대로 실행한다.
#
# 실행:
#   aws sso login --sso-session sbh26
#   export GOOGLE_OAUTH_ACCESS_TOKEN=$(gcloud auth print-access-token --account=alus20x@gmail.com)
#   terraform init && terraform apply
#
# 끝나면 terraform destroy 로 지운다 (VM 2대, EIP, 고정 IP는 켜져 있는 동안 과금됨).

terraform {
  required_version = ">= 1.10"

  required_providers {
    aws       = { source = "hashicorp/aws", version = "~> 6.0" }
    google    = { source = "hashicorp/google", version = "~> 7.0" }
    archive   = { source = "hashicorp/archive", version = "~> 2.7" }
    wireguard = { source = "OJFord/wireguard", version = "~> 0.4" }
  }

  backend "s3" {
    bucket       = "sbh26-org-tfstate-813360232874"
    key          = "poc/cdc-cloud/terraform.tfstate"
    region       = "ap-northeast-2"
    profile      = "mgmt"
    encrypt      = true
    use_lockfile = true
  }
}

provider "aws" {
  region  = "ap-northeast-2"
  profile = "prod"

  default_tags {
    tags = { Project = "sbh26", ManagedBy = "terraform", Stack = "poc-cdc-cloud" }
  }
}

provider "google" {
  project = "sbh26-prod"
  region  = "asia-northeast3"
  zone    = "asia-northeast3-a"

  default_labels = { project = "sbh26", managed-by = "terraform", stack = "poc-cdc-cloud" }
}
