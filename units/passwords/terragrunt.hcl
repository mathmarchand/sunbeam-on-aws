include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "${dirname(find_in_parent_folders("root.hcl"))}/modules/lab-passwords"
}

# Override the generated passwords with MAAS_ADMIN_PASSWORD / SUNBEAM_DEMO_PASSWORD.
inputs = {
  maas_admin_password = get_env("MAAS_ADMIN_PASSWORD", "")
  demo_password       = get_env("SUNBEAM_DEMO_PASSWORD", "")
}
