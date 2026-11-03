# 팀원은 각자의 Google 계정으로 로그인합니다. 프로젝트 단위로 Editor를 부여합니다.
# 프로젝트를 만든 계정(alus20x@gmail.com)은 자동으로 Owner가 됩니다.
resource "google_project_iam_member" "team_editor" {
  for_each = local.team_bindings

  project = google_project.this[each.value.env].project_id
  role    = "roles/editor"
  member  = each.value.member
}
