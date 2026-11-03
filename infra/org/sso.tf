locals {
  permission_sets = {
    admin = {
      name   = "AdministratorAccess"
      policy = "arn:aws:iam::aws:policy/AdministratorAccess"
    }
    readonly = {
      name   = "ReadOnlyAccess"
      policy = "arn:aws:iam::aws:policy/ReadOnlyAccess"
    }
  }

  # 그룹 x 워크로드 계정 조합. Executor가 생기면 prod의 admin 할당을 비상용으로 줄입니다.
  assignments = {
    for pair in setproduct(keys(local.permission_sets), local.workloads) :
    "${pair[0]}/${pair[1]}" => { group = pair[0], account = pair[1] }
  }
}

# 권한 세트

resource "aws_ssoadmin_permission_set" "this" {
  for_each = local.permission_sets

  instance_arn     = local.sso_instance_arn
  name             = each.value.name
  session_duration = "PT8H"
}

resource "aws_ssoadmin_managed_policy_attachment" "this" {
  for_each = local.permission_sets

  instance_arn       = local.sso_instance_arn
  permission_set_arn = aws_ssoadmin_permission_set.this[each.key].arn
  managed_policy_arn = each.value.policy
}

# 사용자와 그룹

resource "aws_identitystore_user" "this" {
  for_each = var.users

  identity_store_id = local.identity_store_id
  user_name         = each.key
  display_name      = "${each.value.given_name} ${each.value.family_name}"

  name {
    given_name  = each.value.given_name
    family_name = each.value.family_name
  }

  emails {
    value   = each.value.email
    type    = "work"
    primary = true
  }
}

resource "aws_identitystore_group" "this" {
  for_each = local.permission_sets

  identity_store_id = local.identity_store_id
  display_name      = each.key
}

resource "aws_identitystore_group_membership" "this" {
  for_each = var.users

  identity_store_id = local.identity_store_id
  group_id          = aws_identitystore_group.this[each.value.role].group_id
  member_id         = aws_identitystore_user.this[each.key].user_id
}

# 할당: 그룹 -> 워크로드 계정

resource "aws_ssoadmin_account_assignment" "workloads" {
  for_each = local.assignments

  instance_arn       = local.sso_instance_arn
  permission_set_arn = aws_ssoadmin_permission_set.this[each.value.group].arn
  principal_type     = "GROUP"
  principal_id       = aws_identitystore_group.this[each.value.group].group_id
  target_type        = "AWS_ACCOUNT"
  target_id          = aws_organizations_account.this[each.value.account].id
}

# 할당: 관리 계정은 조직 관리자만

resource "aws_ssoadmin_account_assignment" "management_admin" {
  instance_arn       = local.sso_instance_arn
  permission_set_arn = aws_ssoadmin_permission_set.this["admin"].arn
  principal_type     = "USER"
  principal_id       = aws_identitystore_user.this[var.org_admin].user_id
  target_type        = "AWS_ACCOUNT"
  target_id          = local.management_account_id
}
