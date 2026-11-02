terraform {
  required_version = ">= 1.8"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.33"
    }
    tls = {
      source  = "hashicorp/tls"
      version = ">= 4.0"
    }
    local = {
      source  = "hashicorp/local"
      version = ">= 2.5"
    }
  }
}

provider "aws" {
  region = var.region
  default_tags {
    tags = var.tags
  }
}

# One lab key pair, used for: the EC2 host, MAAS-deployed machines (registered
# in MAAS) and sbdeploy. It is also copied to the EC2 host so you can hop from
# there to any lab VM.
resource "tls_private_key" "lab" {
  algorithm = "ED25519"
}

resource "aws_key_pair" "lab" {
  key_name   = var.name
  public_key = tls_private_key.lab.public_key_openssh
}

resource "local_sensitive_file" "private_key" {
  content         = tls_private_key.lab.private_key_openssh
  filename        = "${var.output_dir}/${var.name}"
  file_permission = "0600"
}

resource "local_file" "public_key" {
  content         = tls_private_key.lab.public_key_openssh
  filename        = "${var.output_dir}/${var.name}.pub"
  file_permission = "0644"
}
