variable "maas_api_url" {
  description = "MAAS API URL reachable from where Terraform runs."
  type        = string
}

variable "maas_internal_url" {
  description = "MAAS API URL reachable from sbdeploy (registered in Sunbeam)."
  type        = string
}

variable "maas_api_key" {
  type      = string
  sensitive = true
}

variable "maas_ip" {
  type = string
}

variable "maas_ready" {
  description = "Opaque value from maas-config; a change re-deploys sbdeploy."
  type        = string
  default     = ""
}

variable "hostname" {
  type    = string
  default = "sbdeploy"
}

variable "ubuntu_release" {
  type    = string
  default = "noble"
}

variable "bastion_host" {
  description = "EC2 lab host public IP."
  type        = string
}

variable "bastion_user" {
  type    = string
  default = "ubuntu"
}

variable "ssh_private_key" {
  type      = string
  sensitive = true
}

variable "ssh_private_key_path" {
  type = string
}

variable "output_dir" {
  description = "Local directory for the rendered manifest and ssh_config."
  type        = string
}

variable "lab_cidr" {
  type    = string
  default = "10.70.0.0/24"
}

variable "lab_gateway" {
  type    = string
  default = "10.70.0.1"
}

variable "floating_ip_range" {
  type = object({ start = string, end = string })
}

variable "physnet_tag" {
  type    = string
  default = "neutron:physnet1"
}

variable "deployment_name" {
  type    = string
  default = "lab"
}

variable "space_name" {
  type    = string
  default = "sunbeam"
}

variable "openstack_channel" {
  type    = string
  default = "2024.1/stable"
}

variable "openstack_region" {
  type    = string
  default = "RegionOne"
}

variable "database" {
  description = "Sunbeam database topology: single or multi."
  type        = string
  default     = "single"

  validation {
    condition     = contains(["single", "multi"], var.database)
    error_message = "database must be single or multi."
  }
}

variable "demo_username" {
  type    = string
  default = "demo"
}

variable "demo_password" {
  type      = string
  sensitive = true
}

variable "demo_cidr" {
  type    = string
  default = "192.168.0.0/24"
}

variable "demo_nameservers" {
  type    = list(string)
  default = ["8.8.8.8"]
}
