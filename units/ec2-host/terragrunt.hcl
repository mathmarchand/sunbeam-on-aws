include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "${dirname(find_in_parent_folders("root.hcl"))}/modules/aws-ec2-host"
}

dependency "vpc" {
  config_path = values.vpc_path
  mock_outputs = {
    vpc_id           = "vpc-00000000"
    public_subnet_id = "subnet-00000000"
  }
  mock_outputs_allowed_terraform_commands = ["init", "validate", "plan"]
}

dependency "ssh_key" {
  config_path = values.ssh_key_path
  mock_outputs = {
    key_name = "mock"
  }
  mock_outputs_allowed_terraform_commands = ["init", "validate", "plan"]
}

inputs = {
  name             = values.name
  region           = values.region
  tags             = values.tags
  instance_type    = values.instance_type
  root_volume_size = values.root_volume_size
  admin_cidrs      = values.admin_cidrs
  expose_maas_api  = values.expose_maas_api
  vpc_id           = dependency.vpc.outputs.vpc_id
  subnet_id        = dependency.vpc.outputs.public_subnet_id
  key_name         = dependency.ssh_key.outputs.key_name
}
