output "sso_start_url" {
  value = "https://${local.identity_store_id}.awsapps.com/start"
}

output "permission_sets" {
  value = { for k, v in aws_ssoadmin_permission_set.this : k => v.name }
}
