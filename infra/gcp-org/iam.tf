# 팀원은 각자의 Google 계정으로 로그인합니다. 프로젝트 단위로 Editor와 Project IAM Admin을 부여합니다.
# 프로젝트를 만든 계정(alus20x@gmail.com)은 자동으로 Owner가 됩니다.
resource "google_project_iam_member" "team_editor" {
  for_each = local.team_bindings

  project = google_project.this[each.value.env].project_id
  role    = "roles/editor"
  member  = each.value.member
}

# Editor에는 setIamPolicy가 없어서 GKE 노드 서비스 계정 등에 역할을 붙일 수 없습니다(2026-11-05 팀원 요청).
# Owner는 조직 밖 계정(gmail.com)에 API로 부여할 수 없으므로(콘솔 초대와 수락 필요) 이 역할을 더해 사실상 같은 권한을 줍니다.
resource "google_project_iam_member" "team_iam_admin" {
  for_each = local.team_bindings

  project = google_project.this[each.value.env].project_id
  role    = "roles/resourcemanager.projectIamAdmin"
  member  = each.value.member
}
