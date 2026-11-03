# 서울 리전만 허용합니다. AWS의 DenyOutsideSeoul SCP에 대응합니다.
# 전역 리소스(예: 예산, IAM)는 이 제약 조건의 대상이 아닙니다.
resource "google_organization_policy" "resource_locations" {
  org_id     = local.org_id
  constraint = "constraints/gcp.resourceLocations"

  list_policy {
    allow {
      values = ["in:asia-northeast3-locations"]
    }
  }
}

# 서비스 계정 키 생성 금지(iam.managed.disableServiceAccountKeyCreation) 등은
# 새 조직에 기본으로 적용되어 있어 여기서 따로 관리하지 않습니다 (작업 기록 7.4절).
