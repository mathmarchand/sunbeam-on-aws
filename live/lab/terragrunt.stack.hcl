# MAAS + Canonical OpenStack (Sunbeam) lab on a single EC2 host.
#
#   export AWS_PROFILE=...                      # or any AWS credentials
#   export LAB_ADMIN_CIDRS="$(curl -s https://checkip.amazonaws.com)/32"
#   cd live/lab
#   terragrunt stack generate
#   terragrunt stack run apply
#
# Then follow the "next_steps" output of the sbdeploy unit.

locals {
  name   = "sunbeam-lab"
  region = get_env("AWS_REGION", "us-east-1")
  tags = {
    Project   = "sunbeam-lab"
    ManagedBy = "terragrunt"
  }

  # Comma separated list of CIDRs allowed to reach SSH and the MAAS API.
  admin_cidrs = [for c in split(",", get_env("LAB_ADMIN_CIDRS")) : trimspace(c) if trimspace(c) != ""]

  # 32 vCPU / 128 GiB, nested virtualization on a non-metal instance.
  instance_type = "m8i.8xlarge"

  output_dir = "${get_terragrunt_dir()}/generated"

  # Internal lab network (br-maas). Host = .1, MAAS container = .2.
  lab_cidr = "10.70.0.0/24"
  maas_ip  = "10.70.0.2"

  # Sunbeam deployment name: drives the openstack-<name> tag and the
  # <name>-internal-api / <name>-public-api range comments.
  deployment_name = "lab"
  physnet_tag     = "neutron:physnet1"

  ubuntu_release = "noble"

  # Full HA layout from instruction.md (section 0). For a smaller lab set
  # juju_controllers / sunbeam_controllers to 1 (64 GiB still required).
  workers             = 3
  juju_controllers    = 3
  sunbeam_controllers = 3

  machines = merge(
    # OpenStack workers: control+compute+storage, ceph disk + neutron NIC.
    { for n in range(1, local.workers + 1) : "sb${n}" => {
      cores = 16, memory = 32768, disks_gb = [100, 20]
      roles = ["control", "compute", "storage"], provider_nic = true
    } },
    # Dedicated HA Juju controller (must not be collocated with the workers).
    { for n in range(1, local.juju_controllers + 1) : "jc${n}" => {
      cores = 2, memory = 4096, disks_gb = [40], roles = ["juju-controller"]
    } },
    # Dedicated Sunbeam infra nodes (openstack-infra model).
    { for n in range(1, local.sunbeam_controllers + 1) : "sbc${n}" => {
      cores = 2, memory = 4096, disks_gb = [40], roles = ["sunbeam"]
    } },
    # Jump/deployment node, not part of the OpenStack deployment.
    { sbdeploy = { cores = 4, memory = 6000, disks_gb = [80], openstack_member = false } },
  )

  # unit paths inside .terragrunt-stack/
  paths = {
    vpc         = "../vpc"
    ssh_key     = "../ssh-key"
    passwords   = "../passwords"
    ec2_host    = "../ec2-host"
    lxd_maas    = "../lxd-maas"
    maas_config = "../maas-config"
  }
}

unit "vpc" {
  source = "../../units/vpc"
  path   = "vpc"
  values = {
    name          = local.name
    region        = local.region
    tags          = local.tags
    instance_type = local.instance_type
    lab_cidr      = local.lab_cidr
  }
}

unit "ssh-key" {
  source = "../../units/ssh-key"
  path   = "ssh-key"
  values = {
    name       = local.name
    region     = local.region
    tags       = local.tags
    output_dir = local.output_dir
  }
}

unit "passwords" {
  source = "../../units/passwords"
  path   = "passwords"
}

unit "ec2-host" {
  source = "../../units/ec2-host"
  path   = "ec2-host"
  values = {
    name             = local.name
    region           = local.region
    tags             = local.tags
    instance_type    = local.instance_type
    root_volume_size = 500
    admin_cidrs      = local.admin_cidrs
    expose_maas_api  = true
    vpc_path         = local.paths.vpc
    ssh_key_path     = local.paths.ssh_key
  }
}

unit "lxd-maas" {
  source = "../../units/lxd-maas"
  path   = "lxd-maas"
  values = {
    lab_cidr            = local.lab_cidr
    maas_ip             = local.maas_ip
    expose_maas_api     = true
    lxd_channel         = "5.21/stable"
    lxd_storage_size_gb = 400
    maas_channel        = "3.7/stable"
    maas_admin_username = "admin"
    ec2_host_path       = local.paths.ec2_host
    ssh_key_path        = local.paths.ssh_key
    passwords_path      = local.paths.passwords
  }
}

unit "maas-config" {
  source = "../../units/maas-config"
  path   = "maas-config"
  values = {
    deployment_name          = local.deployment_name
    ubuntu_release           = local.ubuntu_release
    space_name               = "sunbeam"
    physnet_tag              = local.physnet_tag
    ceph_tag                 = "ceph"
    extra_ssh_public_keys    = []
    cpu_over_commit_ratio    = 4
    memory_over_commit_ratio = 2

    dynamic_range      = { start = "10.70.0.100", end = "10.70.0.200" }
    internal_api_range = { start = "10.70.0.210", end = "10.70.0.219" }
    public_api_range   = { start = "10.70.0.220", end = "10.70.0.229" }
    floating_ip_range  = { start = "10.70.0.231", end = "10.70.0.250" }

    machines = local.machines

    ec2_host_path = local.paths.ec2_host
    ssh_key_path  = local.paths.ssh_key
    lxd_maas_path = local.paths.lxd_maas
  }
}

unit "sbdeploy" {
  source = "../../units/sbdeploy"
  path   = "sbdeploy"
  values = {
    output_dir        = local.output_dir
    hostname          = "sbdeploy"
    ubuntu_release    = local.ubuntu_release
    physnet_tag       = local.physnet_tag
    openstack_channel = "2024.1/stable"
    openstack_region  = "RegionOne"
    database          = "single"

    ec2_host_path    = local.paths.ec2_host
    ssh_key_path     = local.paths.ssh_key
    passwords_path   = local.paths.passwords
    lxd_maas_path    = local.paths.lxd_maas
    maas_config_path = local.paths.maas_config
  }
}
