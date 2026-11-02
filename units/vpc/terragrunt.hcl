include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "${dirname(find_in_parent_folders("root.hcl"))}/modules/aws-vpc"
}

inputs = {
  name               = values.name
  region             = values.region
  tags               = values.tags
  instance_type      = values.instance_type
  availability_zone  = try(values.availability_zone, "")
  vpc_cidr           = try(values.vpc_cidr, "10.0.0.0/16")
  public_subnet_cidr = try(values.public_subnet_cidr, "10.0.1.0/24")
  lab_cidr           = values.lab_cidr
}
