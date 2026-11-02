include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "${dirname(find_in_parent_folders("root.hcl"))}/modules/lxd-maas"
}

dependency "ec2_host" {
  config_path = values.ec2_host_path
  mock_outputs = {
    instance_id = "i-00000000"
    public_ip   = "192.0.2.10"
  }
  mock_outputs_allowed_terraform_commands = ["init", "validate", "plan"]
}

dependency "ssh_key" {
  config_path = values.ssh_key_path
  mock_outputs = {
    public_key_openssh  = "ssh-ed25519 AAAA mock"
    private_key_openssh = "mock"
    private_key_path    = "/dev/null"
  }
  mock_outputs_allowed_terraform_commands = ["init", "validate", "plan"]
}

dependency "passwords" {
  config_path = values.passwords_path
  mock_outputs = {
    maas_admin_password = "mock"
  }
  mock_outputs_allowed_terraform_commands = ["init", "validate", "plan"]
}

inputs = {
  host                 = dependency.ec2_host.outputs.public_ip
  instance_id          = dependency.ec2_host.outputs.instance_id
  ssh_private_key      = dependency.ssh_key.outputs.private_key_openssh
  ssh_private_key_path = dependency.ssh_key.outputs.private_key_path
  ssh_public_key       = dependency.ssh_key.outputs.public_key_openssh
  lab_cidr             = values.lab_cidr
  maas_ip              = values.maas_ip
  expose_maas_api      = values.expose_maas_api
  lxd_channel          = values.lxd_channel
  lxd_storage_size_gb  = values.lxd_storage_size_gb
  maas_channel         = values.maas_channel
  maas_admin_username  = values.maas_admin_username
  maas_admin_password  = dependency.passwords.outputs.maas_admin_password
}
