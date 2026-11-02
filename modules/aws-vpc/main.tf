terraform {
  required_version = ">= 1.8"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.33" # first release with cpu_options.nested_virtualization
    }
  }
}

provider "aws" {
  region = var.region
  default_tags {
    tags = var.tags
  }
}

# m8i is not offered in every AZ: pick one that actually has the instance type
# unless the caller pinned an AZ explicitly.
data "aws_ec2_instance_type_offerings" "this" {
  location_type = "availability-zone"
  filter {
    name   = "instance-type"
    values = [var.instance_type]
  }
}

locals {
  offered_azs = sort(data.aws_ec2_instance_type_offerings.this.locations)
  az          = var.availability_zone != "" ? var.availability_zone : local.offered_azs[0]
}

resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = "${var.name}-vpc" }

  lifecycle {
    precondition {
      condition     = length(local.offered_azs) > 0 || var.availability_zone != ""
      error_message = "Instance type ${var.instance_type} is not offered in any AZ of ${var.region}."
    }
    # The lab bridge (10.70.0.0/24 by default) is routed locally on the host;
    # it must not overlap with the VPC.
    precondition {
      condition     = !(cidrcontains(var.vpc_cidr, cidrhost(var.lab_cidr, 0)) || cidrcontains(var.lab_cidr, cidrhost(var.vpc_cidr, 0)))
      error_message = "vpc_cidr (${var.vpc_cidr}) overlaps the internal lab subnet (${var.lab_cidr})."
    }
  }
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = "${var.name}-igw" }
}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.this.id
  cidr_block              = var.public_subnet_cidr
  availability_zone       = local.az
  map_public_ip_on_launch = true
  tags                    = { Name = "${var.name}-public" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = "${var.name}-public" }

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}
