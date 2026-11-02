output "instance_id" {
  value = aws_instance.host.id
}

output "public_ip" {
  value = aws_eip.host.public_ip
}

output "private_ip" {
  value = aws_instance.host.private_ip
}

output "ssh_user" {
  value = "ubuntu"
}
