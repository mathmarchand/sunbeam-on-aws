terraform {
  required_version = ">= 1.8"
  required_providers {
    maas = {
      source  = "canonical/maas"
      version = ">= 2.10"
    }
    local = {
      source  = "hashicorp/local"
      version = ">= 2.5"
    }
  }
}

provider "maas" {
  api_version = "2.0"
  api_url     = var.maas_api_url
  api_key     = var.maas_api_key
}

# 5.1: deploy the jump/deployment node. Waits for "Deployed".
resource "maas_instance" "sbdeploy" {
  allocate_params {
    hostname = var.hostname
  }

  deploy_params {
    distro_series = var.ubuntu_release
  }

  timeouts {
    create = "60m"
  }

  lifecycle {
    # Re-deploy when the MAAS side was rebuilt.
    replace_triggered_by = [terraform_data.maas_ready]
  }
}

resource "terraform_data" "maas_ready" {
  input = var.maas_ready
}

locals {
  lab_prefix   = split("/", var.lab_cidr)[1]
  sbdeploy_ips = [for ip in maas_instance.sbdeploy.ip_addresses : ip if cidrhost("${ip}/${local.lab_prefix}", 0) == cidrhost(var.lab_cidr, 0)]
  sbdeploy_ip  = sort(local.sbdeploy_ips)[0]

  manifest = templatefile("${path.module}/templates/manifest.yaml.tftpl", {
    database         = var.database
    region           = var.openstack_region
    lab_cidr         = var.lab_cidr
    lab_gateway      = var.lab_gateway
    floating_start   = var.floating_ip_range.start
    floating_end     = var.floating_ip_range.end
    physnet_tag      = var.physnet_tag
    demo_username    = var.demo_username
    demo_password    = var.demo_password
    demo_cidr        = var.demo_cidr
    demo_nameservers = join(" ", var.demo_nameservers)
  })

  env = {
    OPENSTACK_CHANNEL = var.openstack_channel
    DEPLOYMENT        = var.deployment_name
    MAAS_URL          = var.maas_internal_url
    MAAS_API_KEY      = var.maas_api_key
    SPACE             = var.space_name
  }
  env_file = join("\n", [for k, v in local.env : "${k}='${replace(v, "'", "'\\''")}'"])
}

# 5.2, 5.4, 5.4bis, 5.5 on sbdeploy, through the EC2 host as bastion.
resource "terraform_data" "sunbeam_setup" {
  triggers_replace = [
    maas_instance.sbdeploy.id,
    filesha256("${path.module}/scripts/sunbeam-setup.sh"),
    sha256(local.env_file),
  ]

  connection {
    type        = "ssh"
    host        = local.sbdeploy_ip
    user        = "ubuntu"
    private_key = var.ssh_private_key
    timeout     = "15m"

    bastion_host        = var.bastion_host
    bastion_user        = var.bastion_user
    bastion_private_key = var.ssh_private_key
  }

  provisioner "remote-exec" {
    inline = ["mkdir -p -m 700 ~/.config/sunbeam-lab"]
  }
  provisioner "file" {
    content     = local.env_file
    destination = "/home/ubuntu/.config/sunbeam-lab/lab.env"
  }
  provisioner "file" {
    source      = "${path.module}/scripts/sunbeam-setup.sh"
    destination = "/home/ubuntu/.config/sunbeam-lab/sunbeam-setup.sh"
  }
  provisioner "remote-exec" {
    inline = [
      "chmod 600 ~/.config/sunbeam-lab/lab.env",
      "bash ~/.config/sunbeam-lab/sunbeam-setup.sh",
    ]
  }
}

# Kept separate so editing the manifest doesn't re-run the setup.
resource "terraform_data" "manifest" {
  triggers_replace = [
    maas_instance.sbdeploy.id,
    sha256(local.manifest),
  ]

  connection {
    type        = "ssh"
    host        = local.sbdeploy_ip
    user        = "ubuntu"
    private_key = var.ssh_private_key

    bastion_host        = var.bastion_host
    bastion_user        = var.bastion_user
    bastion_private_key = var.ssh_private_key
  }

  provisioner "file" {
    content     = local.manifest
    destination = "/home/ubuntu/manifest.yaml"
  }
  provisioner "remote-exec" {
    inline = ["chmod 600 ~/manifest.yaml"]
  }
}

resource "local_sensitive_file" "manifest" {
  content         = local.manifest
  filename        = "${var.output_dir}/manifest.yaml"
  file_permission = "0600"
}

resource "local_file" "ssh_config" {
  filename        = "${var.output_dir}/ssh_config"
  file_permission = "0644"
  content         = <<-EOT
    # ssh -F ${abspath("${var.output_dir}/ssh_config")} sbdeploy
    Host lab-host
      HostName ${var.bastion_host}
      User ${var.bastion_user}
      IdentityFile ${var.ssh_private_key_path}
      IdentitiesOnly yes
      StrictHostKeyChecking accept-new
      # MAAS UI on http://localhost:5240/MAAS
      LocalForward 5240 ${var.maas_ip}:5240

    Host sbdeploy
      HostName ${local.sbdeploy_ip}
      User ubuntu
      IdentityFile ${var.ssh_private_key_path}
      IdentitiesOnly yes
      ProxyJump lab-host
      StrictHostKeyChecking no
      UserKnownHostsFile /dev/null

    # Any other lab machine: ssh -F ... ubuntu@10.70.0.x
    Host ${replace(cidrhost(var.lab_cidr, 0), "/\\.0$/", ".*")}
      User ubuntu
      IdentityFile ${var.ssh_private_key_path}
      IdentitiesOnly yes
      ProxyJump lab-host
      StrictHostKeyChecking no
      UserKnownHostsFile /dev/null
  EOT
}
