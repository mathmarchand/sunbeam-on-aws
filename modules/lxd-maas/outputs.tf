output "maas_api_key" {
  value     = data.external.maas_apikey.result.api_key
  sensitive = true
}

output "maas_api_url" {
  description = "MAAS API as reached from outside (DNAT through the host)."
  value       = "http://${var.host}:5240/MAAS"
}

output "maas_internal_url" {
  description = "MAAS API as reached from the lab network (used by Sunbeam)."
  value       = "http://${var.maas_ip}:5240/MAAS"
}

output "maas_ip" {
  value = var.maas_ip
}

output "rack_controller_hostname" {
  value = "maas"
}

output "lab_cidr" {
  value = var.lab_cidr
}

output "lab_gateway" {
  value = local.lab_gateway
}

output "lxd_api_url" {
  description = "LXD API as reached by MAAS (VM host power address)."
  value       = "https://${local.lab_gateway}:8443"
}
