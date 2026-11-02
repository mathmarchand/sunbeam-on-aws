variable "host" {
  description = "Public IP/DNS of the EC2 lab host."
  type        = string
}

variable "instance_id" {
  description = "EC2 instance ID; a new instance re-runs every step."
  type        = string
}

variable "ssh_user" {
  type    = string
  default = "ubuntu"
}

variable "ssh_private_key" {
  description = "Lab private key (OpenSSH format)."
  type        = string
  sensitive   = true
}

variable "ssh_private_key_path" {
  description = "Path of the same private key on disk (used by the local API key fetch)."
  type        = string
}

variable "ssh_public_key" {
  type = string
}

variable "lab_cidr" {
  description = "Internal lab subnet on br-maas. The host takes .1."
  type        = string
  default     = "10.70.0.0/24"
}

variable "maas_ip" {
  description = "Static IP of the MAAS container."
  type        = string
  default     = "10.70.0.2"
}

variable "expose_maas_api" {
  description = "DNAT the host's TCP/5240 to the MAAS container (needed for the Terraform MAAS provider)."
  type        = bool
  default     = true
}

variable "lxd_channel" {
  description = "MAAS 3.7 is not compatible with LXD 6: keep 5.21."
  type        = string
  default     = "5.21/stable"
}

variable "lxd_storage_size_gb" {
  description = "Size of the LXD ZFS loop pool."
  type        = number
  default     = 400
}

variable "maas_channel" {
  type    = string
  default = "3.7/stable"
}

variable "maas_admin_username" {
  type    = string
  default = "admin"
}

variable "maas_admin_password" {
  type      = string
  sensitive = true
}

variable "maas_admin_email" {
  type    = string
  default = "admin@lab.local"
}
