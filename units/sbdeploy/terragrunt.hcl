include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "${dirname(find_in_parent_folders("root.hcl"))}/modules/sbdeploy"
}

dependency "ec2_host" {
  config_path = values.ec2_host_path
  mock_outputs = {
    public_ip = "192.0.2.10"
  }
  mock_outputs_allowed_terraform_commands = ["init", "validate", "plan"]
}

dependency "ssh_key" {
  config_path = values.ssh_key_path
  mock_outputs = {
    private_key_openssh = "mock"
    private_key_path    = "/dev/null"
  }
  mock_outputs_allowed_terraform_commands = ["init", "validate", "plan"]
}

dependency "passwords" {
  config_path = values.passwords_path
  mock_outputs = {
    demo_password = "mock"
  }
  mock_outputs_allowed_terraform_commands = ["init", "validate", "plan"]
}

dependency "lxd_maas" {
  config_path = values.lxd_maas_path
  mock_outputs = {
    maas_api_url      = "http://192.0.2.10:5240/MAAS"
    maas_internal_url = "http://10.70.0.2:5240/MAAS"
    maas_api_key      = "a:b:c"
    maas_ip           = "10.70.0.2"
    lab_cidr          = "10.70.0.0/24"
    lab_gateway       = "10.70.0.1"
  }
  mock_outputs_allowed_terraform_commands = ["init", "validate"]
}

dependency "maas_config" {
  config_path = values.maas_config_path
  mock_outputs = {
    ready             = "mock"
    deployment_name   = "lab"
    space_name        = "sunbeam"
    floating_ip_range = { start = "10.70.0.231", end = "10.70.0.250" }
  }
  mock_outputs_allowed_terraform_commands = ["init", "validate"]
}

inputs = {
  maas_api_url         = dependency.lxd_maas.outputs.maas_api_url
  maas_internal_url    = dependency.lxd_maas.outputs.maas_internal_url
  maas_api_key         = dependency.lxd_maas.outputs.maas_api_key
  maas_ip              = dependency.lxd_maas.outputs.maas_ip
  lab_cidr             = dependency.lxd_maas.outputs.lab_cidr
  lab_gateway          = dependency.lxd_maas.outputs.lab_gateway
  maas_ready           = dependency.maas_config.outputs.ready
  deployment_name      = dependency.maas_config.outputs.deployment_name
  space_name           = dependency.maas_config.outputs.space_name
  floating_ip_range    = dependency.maas_config.outputs.floating_ip_range
  bastion_host         = dependency.ec2_host.outputs.public_ip
  ssh_private_key      = dependency.ssh_key.outputs.private_key_openssh
  ssh_private_key_path = dependency.ssh_key.outputs.private_key_path
  demo_password        = dependency.passwords.outputs.demo_password
  output_dir           = values.output_dir
  hostname             = values.hostname
  ubuntu_release       = values.ubuntu_release
  physnet_tag          = values.physnet_tag
  openstack_channel    = values.openstack_channel
  openstack_region     = values.openstack_region
  database             = values.database
}
