output "folders" {
  value = { for k, v in google_folder.this : k => v.name }
}

output "projects" {
  value = { for k, v in google_project.this : k => { id = v.project_id, number = v.number } }
}
