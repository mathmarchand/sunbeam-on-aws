variable "name" {
  type = string
}

variable "region" {
  type = string
}

variable "tags" {
  type    = map(string)
  default = {}
}

variable "vpc_id" {
  type = string
}

variable "subnet_id" {
  type = string
}

variable "key_name" {
  description = "EC2 key pair name."
  type        = string
}

variable "instance_type" {
  description = "Must support nested virtualization on non-metal sizes (m8i/c8i/r8i)."
  type        = string
  default     = "m8i.8xlarge"

  validation {
    condition     = can(regex("^(m8i|c8i|r8i)(-flex)?\\.", var.instance_type)) || can(regex("\\.metal", var.instance_type))
    error_message = "Use an 8th gen Intel type (m8i/c8i/r8i) or a .metal size; other types do not expose /dev/kvm."
  }
}

variable "ami_id" {
  description = "Override the AMI. Empty = latest Canonical Ubuntu 24.04 amd64."
  type        = string
  default     = ""
}

variable "root_volume_size" {
  description = "Root EBS size in GiB (holds the 400 GiB ZFS loop of LXD)."
  type        = number
  default     = 500
}

variable "admin_cidrs" {
  description = "CIDRs allowed to reach SSH (and the MAAS API if exposed)."
  type        = list(string)

  validation {
    condition     = length(var.admin_cidrs) > 0 && alltrue([for c in var.admin_cidrs : can(cidrhost(c, 0))])
    error_message = "admin_cidrs must contain at least one valid CIDR."
  }
}

variable "expose_maas_api" {
  description = "Open TCP/5240 to admin_cidrs (DNAT-ed to the MAAS container)."
  type        = bool
  default     = true
}
