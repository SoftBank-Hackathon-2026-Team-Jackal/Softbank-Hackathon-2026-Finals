resource "google_folder" "this" {
  for_each = local.workloads

  display_name = each.key
  parent       = "organizations/${local.org_id}"
}
