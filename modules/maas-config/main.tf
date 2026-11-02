terraform {
  required_version = ">= 1.8"
  required_providers {
    maas = {
      source  = "canonical/maas"
      version = ">= 2.10"
    }
    tls = {
      source  = "hashicorp/tls"
      version = ">= 4.0"
    }
  }
}

provider "maas" {
  api_version = "2.0"
  api_url     = var.maas_api_url
  api_key     = var.maas_api_key
}

locals {
  openstack_tag = "openstack-${var.deployment_name}"

  # hostname -> full machine spec, with the roles tag and openstack-<name> tag.
  machines = {
    for name, m in var.machines : name => merge(m, {
      tags = distinct(concat(m.roles, m.openstack_member ? [local.openstack_tag] : []))
    })
  }
  workers = sort([for name, m in local.machines : name if m.provider_nic])

  all_tags = distinct(flatten([for m in local.machines : m.tags]))

  ip_ranges = {
    dynamic = {
      type    = "dynamic"
      start   = var.dynamic_range.start
      end     = var.dynamic_range.end
      comment = "maas-dynamic"
    }
    # Comments must be <deployment>-internal-api / <deployment>-public-api.
    internal_api = {
      type    = "reserved"
      start   = var.internal_api_range.start
      end     = var.internal_api_range.end
      comment = "${var.deployment_name}-internal-api"
    }
    public_api = {
      type    = "reserved"
      start   = var.public_api_range.start
      end     = var.public_api_range.end
      comment = "${var.deployment_name}-public-api"
    }
    floating = {
      type    = "reserved"
      start   = var.floating_ip_range.start
      end     = var.floating_ip_range.end
      comment = "openstack-floating-ips"
    }
  }

  connection = {
    host        = var.host
    user        = var.ssh_user
    private_key = var.ssh_private_key
  }
}

# ---------------------------------------------------------------------------
# Global settings (3.8), SSH key (3.6), boot image (3.5)
# ---------------------------------------------------------------------------
resource "maas_configuration" "upstream_dns" {
  key   = "upstream_dns"
  value = var.upstream_dns
}

resource "maas_configuration" "dnssec_validation" {
  key   = "dnssec_validation"
  value = "no"
}

resource "maas_ssh_keys" "admin" {
  keys = var.ssh_public_keys
}

data "maas_boot_source" "default" {}

# Waits for the image import to finish.
resource "maas_boot_source_selection" "ubuntu" {
  boot_source = tonumber(data.maas_boot_source.default.id)
  os          = "ubuntu"
  release     = var.ubuntu_release
  arches      = ["amd64"]

  timeouts {
    create = "90m"
    update = "90m"
  }
}

# ---------------------------------------------------------------------------
# Lab network: IP ranges, DHCP (3.7), space (5.4bis), reserved VIPs (5.3/5.7)
# ---------------------------------------------------------------------------
data "maas_subnet" "lab" {
  cidr = var.lab_cidr
}

data "maas_fabric" "lab" {
  name = data.maas_subnet.lab.fabric
}

data "maas_rack_controller" "maas" {
  hostname = var.rack_controller_hostname
}

resource "maas_subnet_ip_range" "this" {
  for_each = local.ip_ranges

  subnet   = data.maas_subnet.lab.id
  type     = each.value.type
  start_ip = each.value.start
  end_ip   = each.value.end
  comment  = each.value.comment
}

resource "maas_vlan_dhcp" "lab" {
  fabric                  = tonumber(data.maas_fabric.lab.id)
  vlan                    = data.maas_subnet.lab.vid
  primary_rack_controller = data.maas_rack_controller.maas.id
  subnets                 = [tonumber(data.maas_subnet.lab.id)]

  depends_on = [maas_subnet_ip_range.this]
}

resource "maas_space" "sunbeam" {
  name = var.space_name
}

# The discovered default VLAN can't be managed with maas_vlan (it would be
# deleted on destroy, which MAAS refuses for a default VLAN), so the space
# assignment and the subnet gateway are set via the CLI.
resource "terraform_data" "lab_network" {
  triggers_replace = [
    maas_space.sunbeam.id,
    data.maas_fabric.lab.id,
    data.maas_subnet.lab.vid,
    var.lab_gateway,
  ]

  connection {
    type        = "ssh"
    host        = local.connection.host
    user        = local.connection.user
    private_key = local.connection.private_key
  }

  provisioner "remote-exec" {
    inline = [
      "set -e",
      "sudo lxc exec maas -- maas admin vlan update ${data.maas_fabric.lab.id} ${data.maas_subnet.lab.vid} space=${maas_space.sunbeam.name} >/dev/null",
      "sudo lxc exec maas -- maas admin subnet update ${data.maas_subnet.lab.id} gateway_ip=${var.lab_gateway} >/dev/null",
      "echo 'VLAN ${data.maas_fabric.lab.id}/${data.maas_subnet.lab.vid} -> space ${maas_space.sunbeam.name}, gateway ${var.lab_gateway}'",
    ]
  }

  depends_on = [maas_vlan_dhcp.lab]
}

# ---------------------------------------------------------------------------
# LXD VM host (4): MAAS authenticates to LXD with a client certificate that
# we trust on the host (replaces the one-time trust token).
# ---------------------------------------------------------------------------
resource "tls_private_key" "vmhost" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "tls_self_signed_cert" "vmhost" {
  private_key_pem       = tls_private_key.vmhost.private_key_pem
  validity_period_hours = 24 * 365 * 10
  allowed_uses          = ["digital_signature", "key_encipherment", "client_auth"]

  subject {
    common_name = "maas-vmhost"
  }
}

resource "terraform_data" "lxd_trust" {
  triggers_replace = [sha256(tls_self_signed_cert.vmhost.cert_pem)]

  connection {
    type        = "ssh"
    host        = local.connection.host
    user        = local.connection.user
    private_key = local.connection.private_key
  }

  provisioner "file" {
    content     = tls_self_signed_cert.vmhost.cert_pem
    destination = "/tmp/maas-vmhost.crt"
  }

  provisioner "remote-exec" {
    inline = [
      "set -e",
      "if out=$(sudo lxc config trust add /tmp/maas-vmhost.crt --name maas-vmhost 2>&1); then echo trusted; elif echo \"$out\" | grep -qi already; then echo already-trusted; else echo \"$out\" >&2; exit 1; fi",
      "sudo lxc exec maas -- nc -z -w 5 ${split(":", trimprefix(var.lxd_api_url, "https://"))[0]} 8443",
      "rm -f /tmp/maas-vmhost.crt",
    ]
  }
}

resource "maas_vm_host" "lxd" {
  type                     = "lxd"
  power_address            = var.lxd_api_url
  project                  = "default"
  certificate              = tls_self_signed_cert.vmhost.cert_pem
  key                      = tls_private_key.vmhost.private_key_pem
  cpu_over_commit_ratio    = var.cpu_over_commit_ratio
  memory_over_commit_ratio = var.memory_over_commit_ratio

  # Composing needs: a trusted cert, DHCP for PXE, a synced image, and the
  # upstream DNS for commissioning.
  depends_on = [
    terraform_data.lxd_trust,
    terraform_data.lab_network,
    maas_vlan_dhcp.lab,
    maas_boot_source_selection.ubuntu,
    maas_configuration.upstream_dns,
    maas_configuration.dnssec_validation,
    maas_ssh_keys.admin,
  ]
}

# ---------------------------------------------------------------------------
# Machines (4.1): composed, PXE booted and commissioned; waits for Ready.
# ---------------------------------------------------------------------------
resource "maas_vm_host_machine" "this" {
  for_each = local.machines

  vm_host  = maas_vm_host.lxd.id
  hostname = each.key
  cores    = each.value.cores
  memory   = each.value.memory

  dynamic "storage_disks" {
    for_each = each.value.disks_gb
    content {
      size_gigabytes = storage_disks.value
    }
  }

  timeouts {
    create = "90m"
  }
}

# 4.2: second NIC + recommission + neutron/ceph tags on the workers.
resource "terraform_data" "workers" {
  count = length(local.workers) > 0 ? 1 : 0

  triggers_replace = [
    [for w in local.workers : maas_vm_host_machine.this[w].id],
    filesha256("${path.module}/scripts/configure-workers.sh"),
    var.physnet_tag,
    var.ceph_tag,
  ]

  connection {
    type        = "ssh"
    host        = local.connection.host
    user        = local.connection.user
    private_key = local.connection.private_key
  }

  provisioner "file" {
    source      = "${path.module}/scripts/configure-workers.sh"
    destination = "/tmp/configure-workers.sh"
  }

  provisioner "remote-exec" {
    inline = [
      "sudo bash /tmp/configure-workers.sh '${join(" ", local.workers)}' '${var.physnet_tag}' '${var.ceph_tag}' '${var.lab_bridge}'",
    ]
  }
}

# 4.3: role tags. Applied after the workers are recommissioned and Ready.
resource "maas_tag" "this" {
  for_each = toset(local.all_tags)

  name     = each.key
  machines = [for name, m in local.machines : maas_vm_host_machine.this[name].id if contains(m.tags, each.key)]

  depends_on = [terraform_data.workers]
}
