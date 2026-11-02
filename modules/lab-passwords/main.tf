terraform {
  required_version = ">= 1.8"
  required_providers {
    random = {
      source  = "hashicorp/random"
      version = ">= 3.6"
    }
  }
}

# Passwords are generated once (kept in state) unless provided.
resource "random_password" "maas_admin" {
  length  = 20
  special = false
}

resource "random_password" "demo" {
  length  = 20
  special = false
}

variable "maas_admin_password" {
  description = "Empty = generated."
  type        = string
  default     = ""
  sensitive   = true
}

variable "demo_password" {
  description = "Empty = generated."
  type        = string
  default     = ""
  sensitive   = true
}

output "maas_admin_password" {
  value     = var.maas_admin_password != "" ? var.maas_admin_password : random_password.maas_admin.result
  sensitive = true
}

output "demo_password" {
  value     = var.demo_password != "" ? var.demo_password : random_password.demo.result
  sensitive = true
}
