# GCP 조직 부트스트랩: 조직 관리자(admin@soulee.dev)로 한 번만 실행합니다.
# 평소 작업 계정(alus20x@gmail.com)에 조직 역할을 주고, 외부 Google 계정을 IAM에 추가할 수 있게 합니다.
#
# 실행:
#   export GOOGLE_OAUTH_ACCESS_TOKEN=$(gcloud auth print-access-token --account=admin@soulee.dev)
#   AWS_PROFILE=mgmt terraform apply

terraform {
  required_version = ">= 1.10"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 7.0"
    }
  }

  backend "s3" {
    bucket       = "sbh26-org-tfstate-813360232874"
    key          = "gcp-org/bootstrap/terraform.tfstate"
    region       = "ap-northeast-2"
    profile      = "mgmt"
    encrypt      = true
    use_lockfile = true
  }
}

provider "google" {}

locals {
  org_id    = "994714599350"
  org_admin = "user:admin@soulee.dev"
  operator  = "user:alus20x@gmail.com"
  operator_roles = toset([
    "roles/resourcemanager.organizationAdmin",
    "roles/resourcemanager.folderAdmin",
    "roles/resourcemanager.projectCreator",
    "roles/orgpolicy.policyAdmin",
  ])
}

# organizationAdmin에는 조직 정책을 바꾸는 권한이 없어 따로 부여했습니다 (2026-11-03, gcloud로 먼저 적용).
resource "google_organization_iam_member" "admin_policy_admin" {
  org_id = local.org_id
  role   = "roles/orgpolicy.policyAdmin"
  member = local.org_admin
}

# 새 조직에는 외부 계정을 막는 도메인 제한 정책이 기본으로 적용됩니다.
# 팀원이 각자의 Google 계정(Gmail)을 쓰기로 해서 풀었습니다 (notes/2026-11-03-cloud-setup-log.md 7절).
resource "google_organization_policy" "allowed_member_domains" {
  org_id     = local.org_id
  constraint = "constraints/iam.allowedPolicyMemberDomains"

  list_policy {
    allow {
      all = true
    }
  }
}

resource "google_organization_iam_member" "operator" {
  for_each = local.operator_roles

  org_id = local.org_id
  role   = each.key
  member = local.operator

  depends_on = [google_organization_policy.allowed_member_domains]
}
