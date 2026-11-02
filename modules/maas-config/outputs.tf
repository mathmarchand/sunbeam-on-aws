output "machines" {
  description = "hostname -> system_id"
  value       = { for name, m in maas_vm_host_machine.this : name => m.id }
}

output "machine_tags" {
  value = { for name, m in local.machines : name => m.tags }
}

output "vm_host_id" {
  value = maas_vm_host.lxd.id
}

output "space_name" {
  value = maas_space.sunbeam.name
}

output "deployment_name" {
  value = var.deployment_name
}

output "openstack_tag" {
  value = local.openstack_tag
}

output "floating_ip_range" {
  value = var.floating_ip_range
}

# Lets downstream units wait for the full configuration (tags included).
output "ready" {
  value = sha256(jsonencode([for t in maas_tag.this : t.id]))
}
