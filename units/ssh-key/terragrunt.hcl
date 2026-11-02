include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "${dirname(find_in_parent_folders("root.hcl"))}/modules/aws-ssh-key"
}

inputs = {
  name       = values.name
  region     = values.region
  tags       = values.tags
  output_dir = values.output_dir
}
