output "sbdeploy_ip" {
  value = local.sbdeploy_ip
}

output "ssh_config" {
  value = abspath(local_file.ssh_config.filename)
}

output "manifest_path" {
  value = abspath(local_sensitive_file.manifest.filename)
}

output "next_steps" {
  value = <<-EOT
    ssh -F ${abspath(local_file.ssh_config.filename)} sbdeploy
    sunbeam cluster bootstrap --manifest ~/manifest.yaml
    sunbeam cluster deploy
    sunbeam configure --openrc ~/demo-openrc
  EOT
}
