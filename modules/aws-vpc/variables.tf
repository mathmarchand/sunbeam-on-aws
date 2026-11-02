variable "name" {
  description = "Name prefix for all resources."
  type        = string
}

variable "region" {
  description = "AWS region."
  type        = string
}

variable "tags" {
  description = "Tags applied to every resource."
  type        = map(string)
  default     = {}
}

variable "instance_type" {
  description = "Instance type the lab host will use (used to pick an AZ that offers it)."
  type        = string
}

variable "availability_zone" {
  description = "Force a specific AZ. Empty = first AZ offering instance_type."
  type        = string
  default     = ""
}

variable "vpc_cidr" {
  description = "VPC CIDR."
  type        = string
  default     = "10.0.0.0/16"
}

variable "public_subnet_cidr" {
  description = "Public subnet CIDR (must be inside vpc_cidr)."
  type        = string
  default     = "10.0.1.0/24"
}

variable "lab_cidr" {
  description = "Internal MAAS lab subnet on br-maas; only used to check for overlap."
  type        = string
  default     = "10.70.0.0/24"
}
