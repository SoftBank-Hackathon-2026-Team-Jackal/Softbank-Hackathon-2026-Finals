resource "google_project" "this" {
  for_each = local.workloads

  name            = each.key
  project_id      = "sbh26-${each.key}"
  folder_id       = google_folder.this[each.key].folder_id
  billing_account = var.billing_account

  # 기본 VPC를 만들지 않습니다. 네트워크는 env 스택에서 따로 만듭니다.
  auto_create_network = false
}

resource "google_project_service" "this" {
  for_each = local.project_apis

  project = google_project.this[each.value.env].project_id
  service = each.value.api

  disable_on_destroy = false
}
