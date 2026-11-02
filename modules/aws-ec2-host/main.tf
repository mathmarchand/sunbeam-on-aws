terraform {
  required_version = ">= 1.8"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.33" # cpu_options.nested_virtualization
    }
  }
}

provider "aws" {
  region = var.region
  default_tags {
    tags = var.tags
  }
}

data "aws_ami" "ubuntu" {
  count       = var.ami_id == "" ? 1 : 0
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }
  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

locals {
  ami_id = var.ami_id != "" ? var.ami_id : data.aws_ami.ubuntu[0].id
}

resource "aws_security_group" "host" {
  name        = "${var.name}-host"
  description = "MAAS/Sunbeam lab host"
  vpc_id      = var.vpc_id
  tags        = { Name = "${var.name}-host" }
}

resource "aws_vpc_security_group_ingress_rule" "ssh" {
  for_each          = toset(var.admin_cidrs)
  security_group_id = aws_security_group.host.id
  description       = "SSH"
  cidr_ipv4         = each.value
  ip_protocol       = "tcp"
  from_port         = 22
  to_port           = 22
}

# MAAS API/UI, DNAT-ed by the host to the MAAS container. Needed by the
# Terraform MAAS provider (and handy for the web UI).
resource "aws_vpc_security_group_ingress_rule" "maas" {
  for_each          = var.expose_maas_api ? toset(var.admin_cidrs) : toset([])
  security_group_id = aws_security_group.host.id
  description       = "MAAS API/UI"
  cidr_ipv4         = each.value
  ip_protocol       = "tcp"
  from_port         = 5240
  to_port           = 5240
}

resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.host.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

resource "aws_instance" "host" {
  ami                    = local.ami_id
  instance_type          = var.instance_type
  subnet_id              = var.subnet_id
  key_name               = var.key_name
  vpc_security_group_ids = [aws_security_group.host.id]

  # The whole point: real KVM inside a non-metal instance so MAAS can PXE
  # boot/commission/deploy VMs. Only supported on 8th gen Intel (m8i, c8i, r8i).
  cpu_options {
    nested_virtualization = "enabled"
  }

  root_block_device {
    volume_size           = var.root_volume_size
    volume_type           = "gp3"
    delete_on_termination = true
    tags                  = { Name = "${var.name}-root" }
  }

  metadata_options {
    http_tokens = "required"
  }

  tags = { Name = var.name }

  lifecycle {
    ignore_changes = [ami] # don't replace the lab when a newer AMI is published
  }
}

# Stable public address: the downstream units (MAAS provider URL, SSH
# connections) keep working across stop/start of the instance.
resource "aws_eip" "host" {
  domain   = "vpc"
  instance = aws_instance.host.id
  tags     = { Name = var.name }
}
