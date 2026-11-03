resource "aws_organizations_account" "this" {
  for_each = local.workloads

  name      = each.key
  email     = var.account_emails[each.key]
  parent_id = aws_organizations_organizational_unit.this[each.key].id

  # destroy하면 계정을 닫습니다(90일 동안 정지 상태로 남고, 같은 이메일은 다시 쓸 수 없습니다).
  close_on_deletion = true

  lifecycle {
    prevent_destroy = true
    # 생성할 때만 쓰이고 읽어 올 수 없는 값입니다. 바뀌면 계정을 다시 만들려고 합니다.
    ignore_changes = [role_name, iam_user_access_to_billing]
  }
}
