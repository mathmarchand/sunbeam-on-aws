output "key_name" {
  value = aws_key_pair.lab.key_name
}

output "public_key_openssh" {
  value = trimspace(tls_private_key.lab.public_key_openssh)
}

output "private_key_openssh" {
  value     = tls_private_key.lab.private_key_openssh
  sensitive = true
}

output "private_key_path" {
  value = abspath(local_sensitive_file.private_key.filename)
}
