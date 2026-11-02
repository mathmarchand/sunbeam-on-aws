terraform {
  required_version = ">= 1.8"
  required_providers {
    external = {
      source  = "hashicorp/external"
      version = ">= 2.3"
    }
  }
}

locals {
  lab_gateway = cidrhost(var.lab_cidr, 1)
  lab_prefix  = split("/", var.lab_cidr)[1]

  env = {
    LAB_CIDR            = var.lab_cidr
    LAB_GATEWAY         = local.lab_gateway
    LAB_PREFIX          = local.lab_prefix
    MAAS_IP             = var.maas_ip
    EXPOSE_MAAS_API     = tostring(var.expose_maas_api)
    LXD_CHANNEL         = var.lxd_channel
    LXD_STORAGE_GB      = tostring(var.lxd_storage_size_gb)
    MAAS_CHANNEL        = var.maas_channel
    MAAS_ADMIN_USER     = var.maas_admin_username
    MAAS_ADMIN_PASSWORD = var.maas_admin_password
    MAAS_ADMIN_EMAIL    = var.maas_admin_email
  }
  # KEY='value' with single quotes escaped, sourced by the scripts.
  # The file holds the MAAS admin password: each step deletes it when done.
  env_file = join("\n", [for k, v in local.env : "${k}='${replace(v, "'", "'\\''")}'"])
}

# Section 1: host preparation (packages, KVM check, br-maas, NAT, DNS stub).
resource "terraform_data" "host_prep" {
  triggers_replace = [
    var.instance_id,
    filesha256("${path.module}/scripts/host-prep.sh"),
    sha256(local.env_file),
    sha256(var.ssh_public_key),
  ]

  connection {
    type        = "ssh"
    host        = var.host
    user        = var.ssh_user
    private_key = var.ssh_private_key
    timeout     = "10m"
  }

  provisioner "remote-exec" {
    inline = ["mkdir -p /tmp/sunbeam-lab"]
  }
  provisioner "file" {
    source      = "${path.module}/scripts/"
    destination = "/tmp/sunbeam-lab"
  }
  provisioner "file" {
    content     = local.env_file
    destination = "/tmp/sunbeam-lab/lab.env"
  }
  provisioner "file" {
    content     = var.ssh_private_key
    destination = "/tmp/sunbeam-lab/id_lab"
  }
  provisioner "file" {
    content     = "${var.ssh_public_key}\n"
    destination = "/tmp/sunbeam-lab/id_lab.pub"
  }
  provisioner "remote-exec" {
    inline = [
      "sudo bash /tmp/sunbeam-lab/host-prep.sh",
      "rm -f /tmp/sunbeam-lab/lab.env",
    ]
  }
}

# Section 2: LXD 5.21 + VM host prerequisites.
resource "terraform_data" "lxd" {
  depends_on = [terraform_data.host_prep]
  triggers_replace = [
    var.instance_id,
    filesha256("${path.module}/scripts/lxd.sh"),
    sha256(local.env_file),
  ]

  connection {
    type        = "ssh"
    host        = var.host
    user        = var.ssh_user
    private_key = var.ssh_private_key
    timeout     = "10m"
  }

  provisioner "remote-exec" {
    inline = ["mkdir -p /tmp/sunbeam-lab"]
  }
  provisioner "file" {
    source      = "${path.module}/scripts/"
    destination = "/tmp/sunbeam-lab"
  }
  provisioner "file" {
    content     = local.env_file
    destination = "/tmp/sunbeam-lab/lab.env"
  }
  provisioner "remote-exec" {
    inline = [
      "sudo bash /tmp/sunbeam-lab/lxd.sh",
      "rm -f /tmp/sunbeam-lab/lab.env",
    ]
  }
}

# Section 3.1-3.4: MAAS region+rack in the "maas" container.
resource "terraform_data" "maas" {
  depends_on = [terraform_data.lxd]
  triggers_replace = [
    var.instance_id,
    filesha256("${path.module}/scripts/maas.sh"),
    sha256(local.env_file),
  ]

  connection {
    type        = "ssh"
    host        = var.host
    user        = var.ssh_user
    private_key = var.ssh_private_key
    timeout     = "10m"
  }

  provisioner "remote-exec" {
    inline = ["mkdir -p /tmp/sunbeam-lab"]
  }
  provisioner "file" {
    source      = "${path.module}/scripts/"
    destination = "/tmp/sunbeam-lab"
  }
  provisioner "file" {
    content     = local.env_file
    destination = "/tmp/sunbeam-lab/lab.env"
  }
  provisioner "remote-exec" {
    inline = [
      "sudo bash /tmp/sunbeam-lab/maas.sh",
      "rm -f /tmp/sunbeam-lab/lab.env",
    ]
  }
}

data "external" "maas_apikey" {
  depends_on = [terraform_data.maas]
  program = [
    "bash", "${path.module}/scripts/get-apikey.sh",
    var.host, var.ssh_user, var.ssh_private_key_path, var.maas_admin_username,
  ]
}
