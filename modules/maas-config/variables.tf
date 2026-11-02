variable "maas_api_url" {
  type = string
}

variable "maas_api_key" {
  type      = string
  sensitive = true
}

# SSH to the EC2 host, for the few steps the provider can't do.
variable "host" {
  type = string
}

variable "ssh_user" {
  type    = string
  default = "ubuntu"
}

variable "ssh_private_key" {
  type      = string
  sensitive = true
}

variable "ssh_public_keys" {
  description = "Public keys registered in MAAS (installed on every deployed machine)."
  type        = list(string)
}

variable "deployment_name" {
  description = "Sunbeam deployment name: drives the openstack-<name> tag and the <name>-*-api range comments."
  type        = string
  default     = "lab"
}

variable "ubuntu_release" {
  type    = string
  default = "noble"
}

variable "upstream_dns" {
  description = "MAAS upstream DNS (the host's resolved stub on the lab bridge)."
  type        = string
  default     = "10.70.0.1"
}

variable "lab_cidr" {
  type    = string
  default = "10.70.0.0/24"
}

variable "lab_gateway" {
  type    = string
  default = "10.70.0.1"
}

variable "lab_bridge" {
  type    = string
  default = "br-maas"
}

variable "rack_controller_hostname" {
  type    = string
  default = "maas"
}

variable "lxd_api_url" {
  type    = string
  default = "https://10.70.0.1:8443"
}

variable "space_name" {
  type    = string
  default = "sunbeam"
}

variable "physnet_tag" {
  type    = string
  default = "neutron:physnet1"
}

variable "ceph_tag" {
  type    = string
  default = "ceph"
}

variable "cpu_over_commit_ratio" {
  type    = number
  default = 4
}

variable "memory_over_commit_ratio" {
  type    = number
  default = 2
}

variable "dynamic_range" {
  description = "DHCP range for PXE/commissioning."
  type        = object({ start = string, end = string })
  default     = { start = "10.70.0.100", end = "10.70.0.200" }
}

variable "internal_api_range" {
  type    = object({ start = string, end = string })
  default = { start = "10.70.0.210", end = "10.70.0.219" }
}

variable "public_api_range" {
  type    = object({ start = string, end = string })
  default = { start = "10.70.0.220", end = "10.70.0.229" }
}

variable "floating_ip_range" {
  description = "Reserved for the OpenStack external network allocation pool."
  type        = object({ start = string, end = string })
  default     = { start = "10.70.0.231", end = "10.70.0.250" }
}

variable "machines" {
  description = <<-EOT
    VMs composed on the LXD VM host, keyed by hostname.
      roles            : MAAS tags (control/compute/storage, juju-controller, sunbeam, ...)
      openstack_member : add the openstack-<deployment_name> tag
      provider_nic     : add + tag a 2nd NIC (neutron) and tag the extra disk (ceph)
      disks_gb         : first disk is the root disk
  EOT
  type = map(object({
    cores            = number
    memory           = number
    disks_gb         = list(number)
    roles            = optional(list(string), [])
    openstack_member = optional(bool, true)
    provider_nic     = optional(bool, false)
  }))

  validation {
    condition     = alltrue([for m in var.machines : !m.provider_nic || length(m.disks_gb) >= 2])
    error_message = "Machines with provider_nic = true need a second disk for Ceph."
  }
}
