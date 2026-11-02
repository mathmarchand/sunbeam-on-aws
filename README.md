# Sunbeam (Canonical OpenStack) on MAAS on a single EC2 host

Terragrunt stack that automates [instruction.md](instruction.md), sections 0 to 5.5:
one EC2 `m8i.8xlarge` with nested virtualization, LXD 5.21, MAAS 3.7 in a container,
the host registered as an LXD VM host, the HA machine layout composed, tagged and
commissioned, and `sbdeploy` deployed with Sunbeam registered against MAAS.

The long-running Sunbeam steps (`cluster bootstrap`, `cluster deploy`, `configure`) are
left to you. You need to follow them anyway, and a multi-hour SSH provisioner would make
Terraform brittle.

## Layout

```
root.hcl                     shared config (local state in ./state/)
live/lab/terragrunt.stack.hcl  the lab: all settings in one place
units/<unit>/terragrunt.hcl  wiring (dependencies, inputs)
modules/
  aws-vpc        VPC, public subnet, IGW; picks an AZ that offers the instance type
  aws-ssh-key    ed25519 key, EC2 key pair, private key in live/lab/generated/
  lab-passwords  generated MAAS admin / demo passwords
  aws-ec2-host   Ubuntu 24.04, NestedVirtualization=enabled, 500 GB gp3, SG
  lxd-maas       sections 1-3.4 over SSH (bridge, NAT, LXD, MAAS container)
  maas-config    sections 3.5-4.3 with the MAAS provider (+ 2 CLI steps)
  sbdeploy       sections 5.1-5.5 (deploy, snap, deployment add, space map, validate)
```

Units run in dependency order:
`vpc, ssh-key, passwords -> ec2-host -> lxd-maas -> maas-config -> sbdeploy`.

## Prerequisites

- OpenTofu >= 1.8 (or Terraform), Terragrunt with stack support, `bash`, `ssh`, `curl`.
- AWS credentials allowed to manage VPC/EC2, in a region that offers `m8i` instances.

## Usage

```sh
export AWS_REGION=us-east-1
export LAB_ADMIN_CIDRS="$(curl -s https://checkip.amazonaws.com)/32"   # SSH + MAAS API
# optional: export MAAS_ADMIN_PASSWORD=...  SUNBEAM_DEMO_PASSWORD=...

cd live/lab
terragrunt stack generate
terragrunt stack run apply
```

This takes about 45 to 90 minutes. Most of it is the image import and commissioning
the 10 VMs.

Then:

```sh
ssh -F generated/ssh_config sbdeploy
sunbeam cluster bootstrap --manifest ~/manifest.yaml
sunbeam cluster deploy
sunbeam configure --openrc ~/demo-openrc
```

Other useful commands:

```sh
ssh -F generated/ssh_config lab-host       # EC2 host; also forwards the MAAS UI to localhost:5240
lxc exec maas -- maas admin machines read  # on the host (the MAAS() helper is in /etc/profile.d)
cd .terragrunt-stack/passwords && terragrunt output -json   # passwords
```

`terragrunt stack run plan` only works after the first apply. The MAAS units need a live
MAAS, so their dependencies are mocked only for `init`/`validate`.

## Design notes and deviations from instruction.md

- **LXD trust.** MAAS gets a Terraform-generated client certificate that is trusted
  with `lxc config trust add`. This replaces the one-time token from 2.4.
- **MAAS API from Terraform.** The host DNATs `:5240` to the container, and the security
  group only opens it to `LAB_ADMIN_CIDRS`. Sunbeam itself uses the internal URL
  `http://10.70.0.2:5240/MAAS`.
- **Upstream DNS `10.70.0.1`.** systemd-resolved gets an extra stub listener on the
  bridge address, so the upstream DNS set in 3.8 actually answers.
- **Commissioning network.** Inside the MAAS container, cloud-init networking is disabled
  and `dhcp4: false` is set. Without that, the container picks up a second address once
  MAAS DHCP is on.
- **Second NIC and tags (4.2).** No compose parameter or provider resource covers these,
  so `modules/maas-config/scripts/configure-workers.sh` handles them. It only touches
  machines in `Ready`, so re-running it after Sunbeam is deployed is harmless. It also
  finds the provider NIC as "the non-boot interface" rather than by the name `enp6s0`.
- **VLAN space and subnet gateway** are set with the MAAS CLI, not `maas_vlan`. The
  default VLAN is discovered by MAAS, and managing it with `maas_vlan` would try to
  delete it on destroy.
- **Manifest.** `~/manifest.yaml` answers the bootstrap/configure questions, including
  the external network: `10.70.0.0/24`, pool `10.70.0.231-250`, flat (section 5.7).
- **Smaller lab.** Set `juju_controllers` / `sunbeam_controllers` to 1 in the stack file.

## Teardown

```sh
cd live/lab && terragrunt stack run destroy
```

Destroying `ec2-host` is what removes the lab. The MAAS/LXD units only clean up objects
inside it. If the instance is already gone, drop the state of the in-host units and destroy only
the AWS units:

```sh
rm -rf ../../state/live/lab/.terragrunt-stack/{lxd-maas,maas-config,sbdeploy}
for u in ec2-host ssh-key passwords vpc; do (cd .terragrunt-stack/$u && terragrunt destroy); done
```
