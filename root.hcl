# Shared Terragrunt configuration, included by every unit.

locals {
  repo_root = get_parent_terragrunt_dir()
}

# Local state under ./state/ (gitignored). Swap for an S3 backend if the lab
# is shared between several people.
remote_state {
  backend = "local"
  generate = {
    path      = "backend.tf"
    if_exists = "overwrite_terragrunt"
  }
  config = {
    path = "${local.repo_root}/state/${path_relative_to_include()}/terraform.tfstate"
  }
}
