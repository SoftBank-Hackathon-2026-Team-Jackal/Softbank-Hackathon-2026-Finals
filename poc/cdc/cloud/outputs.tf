output "env_a_instance_id" { value = aws_instance.a.id }
output "env_a_public_ip" { value = aws_eip.a.public_ip }
output "env_b_public_ip" { value = google_compute_address.b.address }
output "bundle_url" { value = "s3://${aws_s3_bucket.bundle.id}/${aws_s3_object.bundle.key}" }
