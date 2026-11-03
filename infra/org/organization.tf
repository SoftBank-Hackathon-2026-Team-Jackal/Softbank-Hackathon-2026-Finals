# 예선 때 만든 조직을 2026-11-03에 import했습니다.
resource "aws_organizations_organization" "this" {
  feature_set = "ALL"

  aws_service_access_principals = [
    "cloudtrail.amazonaws.com", # 조직 CloudTrail
    "iam.amazonaws.com",        # 멤버 계정 루트 자격 증명 중앙 관리
    "sso.amazonaws.com",        # Identity Center
  ]

  enabled_policy_types = ["SERVICE_CONTROL_POLICY"]

  lifecycle {
    prevent_destroy = true
  }
}

# 멤버 계정에는 루트 자격 증명(비밀번호, 액세스 키, MFA)을 두지 않습니다.
resource "aws_iam_organizations_features" "this" {
  enabled_features = [
    "RootCredentialsManagement",
    "RootSessions",
  ]

  depends_on = [aws_organizations_organization.this]
}

resource "aws_organizations_organizational_unit" "this" {
  for_each = local.workloads

  name      = each.key
  parent_id = aws_organizations_organization.this.roots[0].id
}
