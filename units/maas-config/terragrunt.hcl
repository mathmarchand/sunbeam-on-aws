include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "${dirname(find_in_parent_folders("root.hcl"))}/modules/maas-config"
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
    public_key_openssh  = "ssh-ed25519 AAAA mock"
    private_key_openssh = "mock"
  }
  mock_outputs_allowed_terraform_commands = ["init", "validate", "plan"]
}

dependency "lxd_maas" {
  config_path = values.lxd_maas_path
  mock_outputs = {
    maas_api_url             = "http://192.0.2.10:5240/MAAS"
    maas_api_key             = "a:b:c"
    lab_cidr                 = "10.70.0.0/24"
    lab_gateway              = "10.70.0.1"
    lxd_api_url              = "https://10.70.0.1:8443"
    rack_controller_hostname = "maas"
  }
  mock_outputs_allowed_terraform_commands = ["init", "validate"]
}

inputs = {
  maas_api_url             = dependency.lxd_maas.outputs.maas_api_url
  maas_api_key             = dependency.lxd_maas.outputs.maas_api_key
  host                     = dependency.ec2_host.outputs.public_ip
  ssh_private_key          = dependency.ssh_key.outputs.private_key_openssh
  ssh_public_keys          = concat([dependency.ssh_key.outputs.public_key_openssh], values.extra_ssh_public_keys)
  lab_cidr                 = dependency.lxd_maas.outputs.lab_cidr
  lab_gateway              = dependency.lxd_maas.outputs.lab_gateway
  upstream_dns             = dependency.lxd_maas.outputs.lab_gateway
  lxd_api_url              = dependency.lxd_maas.outputs.lxd_api_url
  rack_controller_hostname = dependency.lxd_maas.outputs.rack_controller_hostname
  deployment_name          = values.deployment_name
  ubuntu_release           = values.ubuntu_release
  space_name               = values.space_name
  physnet_tag              = values.physnet_tag
  ceph_tag                 = values.ceph_tag
  dynamic_range            = values.dynamic_range
  internal_api_range       = values.internal_api_range
  public_api_range         = values.public_api_range
  floating_ip_range        = values.floating_ip_range
  cpu_over_commit_ratio    = values.cpu_over_commit_ratio
  memory_over_commit_ratio = values.memory_over_commit_ratio
  machines                 = values.machines
}
