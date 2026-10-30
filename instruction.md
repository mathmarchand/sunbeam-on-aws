# MAAS \+ LXD \+ Sunbeam (Canonical OpenStack) HA Lab on a Single EC2 m8i.8xlarge

Build of a self-contained OpenStack lab on **one** EC2 instance.

Overview:

1. Prepare the EC2 host (nested KVM, LXD, networking).  
2. Deploy a **MAAS** region+rack controller inside an LXD container.  
3. Register the EC2 host as a **LXD VM host** in MAAS so MAAS can compose, PXE-boot, commission and deploy brand-new VMs on demand.  
4. Provision 3(sunbeam controller)+3(juju-controller)+3(sunbeam) MAAS-managed VMs and deploy a **3-node HA Sunbeam** cluster on them.  
5. Run a **test suite** that simulates node loss, repowers nodes, validates re-join, and exercises real OpenStack capabilities.

**Important:** Reference documentation: [install-canonical-openstack-using-canonical-maas](https://canonical-openstack.readthedocs-hosted.com/en/latest/how-to/install/install-canonical-openstack-using-canonical-maas/)

> **Important architecture note.** For MAAS to actually boot a *new* OS via PXE, the VMs must be true KVM virtual machines (not system containers). On AWS that requires nested virtualization. Most instance type families exposes nested VT only on bare-metal sizing. A non-metal `m7a.8xlarge` does **not** reliably expose nested VT. Two options:  
> 

> - Use a metal size (e.g. `m7a.metal-48xl` or `c7a.metal-48xl`) so `/dev/kvm` works but that's expensive\!  
  >   
> - **Recommended for true PXE/commissioning:** Use the `m8i` family (ie: `m8i.8xlarge`) which can be started with nested virtualization on AWS:

```sh
aws ec2 run-instances --region "$REGION" --image-id "$AMI" 
          --instance-type "$TYPE" --cpu-options "NestedVirtualization=enabled" 
   --key-name "$KEY" 
          --security-group-ids "$SG_ID" 
          --block-device-mappings '[{"DeviceName":"/dev/sda1","Ebs":{"VolumeSize":500,"VolumeType":"gp3","DeleteOnTermination":true}}]' --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=maas-sunbeam-lab}]'
          --query 'Instances[0].InstanceId' --output text


```

> Verify before proceeding:

```sh
sudo kvm-ok            # expects "KVM acceleration can be used"
ls -l /dev/kvm         # must exist for true VM hosts
```

---

## 0\. Conventions and sizing

**Important note:** this step by step is prepared for a full HA configuration (3 juju-controllers, 3 sunbeam-controllers, 3 sunbeam hyperconverged nodes). If this deployment seems too big for what you have and you want to reduce footprint, it is **feasible** to reduce to 1 juju-controller and 1 sunbeam-controller. Memory footprint can be reduced but still 64G is required 

| Item | Value |
| :---- | :---- |
| EC2 instance | `m8i.8xlarge` (preferred) |
| OS | Ubuntu 24.04 LTS (Noble) |
| Root disk | 500 GB gp3 |
| Lab subnet (internal) | `10.70.0.0/24` on bridge `br-maas` |
| MAAS region/rack | LXD container `maas` at `10.70.0.2` |
| OpenStack worker VMs | `sb1`, `sb2`, `sb3`  |
| Juju controller VMs | `jc1`, `jc2`, `jc3` (HA controller, dedicated) |
| Sunbeam controller VMS | `sbc1`, `sbc2`, `sbc3` (HA controller, dedicated) |
| Bastion host / deploy host | `sbdeploy` jump host |
| Per worker VM | 16 vCPU, 32 GB RAM, root 200 GB \+ OSD 20 GB |
| Per controller VM | 2 vCPU, 4 GB RAM, 40 GB disk |

All commands run as a sudo-capable user named `ubuntu`. Replace IPs only if they collide with your VPC.

---

## 1\. EC2 host preparation

### 1.1 Base packages and updates

```sh
sudo apt update && sudo apt -y full-upgrade
sudo apt -y install jq git make bridge-utils cpu-checker virtinst netcat-openbsd
```

### 1.2 Confirm virtualization

```sh
sudo kvm-ok
ls -l /dev/kvm
```

On a metal instance KVM is available and `/dev/kvm` is present.   
If you are on the `m8i.8xlarge` verify that you started the instance with the correct option and that `dev/kvm` is indeed present.

### 1.3 Create the lab bridge

MAAS needs a network it fully controls (its own DHCP, no AWS DHCP interference). This isolated internal bridge does **not** touch the EC2 primary ENI.

```sh
sudo tee /etc/netplan/99-maas-lab.yaml >/dev/null <<'EOF'
network:
  version: 2
  bridges:
    br-maas:
      addresses: [10.70.0.1/24]
      dhcp4: false
      dhcp6: false
EOF
sudo chmod 600 /etc/netplan/99-maas-lab.yaml
sudo netplan apply
ip addr show br-maas
```

### 1.4 NAT so lab machines reach the internet

```sh
PRIMARY_IF=$(ip route | awk '/default/ {print $5; exit}')
echo "net.ipv4.ip_forward=1" | sudo tee /etc/sysctl.d/99-maas-forward.conf
sudo sysctl --system

sudo apt -y install iptables-persistent
sudo iptables -t nat -A POSTROUTING -s 10.70.0.0/24 -o "$PRIMARY_IF" -j MASQUERADE
sudo iptables -A FORWARD -s 10.70.0.0/24 -j ACCEPT
sudo iptables -A FORWARD -d 10.70.0.0/24 -m state --state ESTABLISHED,RELATED -j ACCEPT
sudo netfilter-persistent save
```

---

## 2\. Install LXD and create the VM host

### 2.1 Install LXD from snap

**Warning here**: There is currently an incompatibility in MAAS with LXD6 so you are currently forced to use LXD 5.21

```sh
sudo apt-get -y purge '*lxd*' '*lxc*' 2>/dev/null || true
sudo apt-get -y autoremove
sudo snap install lxd --channel=5.21/stable
sudo usermod -aG lxd ubuntu
newgrp lxd
```

### 2.2 Initialize LXD

```sh
sudo lxd init --auto \
  --storage-backend=zfs \
  --storage-create-loop=400 \
  --network-address=[::] \
  --network-port=8443
```

### 2.3 Attach LXD to the lab bridge

MAAS owns DHCP, not LXD. Bind the default profile to `br-maas` and neutralize any `lxdbr0` DHCP.

```sh
lxc profile device remove default eth0 2>/dev/null || true
lxc profile device add default eth0 nic nictype=bridged parent=br-maas name=eth0

lxc network set lxdbr0 ipv4.dhcp=false 2>/dev/null || true
lxc network set lxdbr0 ipv6.dhcp=false 2>/dev/null || true
lxc network set lxdbr0 dns.mode=none   2>/dev/null || true
```

### 2.4 Expose the LXD API for MAAS as a VM host

```sh
lxc config set core.https_address [::]:8443
lxc config trust add --name maas-vmhost
# Copy the one-time token it prints; you paste it into the MAAS CLI in step 4.
```

---

## 3\. Deploy MAAS in an LXD container 

### 3.1 Launch the MAAS container

```sh
lxc launch ubuntu:24.04 maas
```

Pin the lab IP:

```sh

# verify that that system is UP before applying changes

lxc exec maas -- bash -c '
cat >/etc/netplan/60-maas.yaml <<EOF
network:
  version: 2
  ethernets:
    eth0:
      addresses: [10.70.0.2/24]
      routes:
        - to: default
          via: 10.70.0.1
      nameservers:
        addresses: [10.70.0.1, 8.8.8.8]
EOF
chmod 600 /etc/netplan/60-maas.yaml
netplan apply'
```

Verify:

```sh
lxc exec maas -- bash -c 'until ping -c1 8.8.8.8 >/dev/null 2>&1; do sleep 2; done; echo net-ok'
```

### 3.2 Install MAAS (region \+ rack) and PostgreSQL

```sh
lxc exec maas -- snap install --channel=3.7/stable maas 
lxc exec maas -- snap install maas-test-db 
lxc exec maas -- maas init region+rack --maas-url http://10.70.0.2:5240/MAAS --database-uri maas-test-db:///
```

### 3.3 Create the admin user

```sh
lxc exec maas -- maas createadmin \
  --username admin --password 'ChangeMe123!' --email admin@lab.local
```

### 3.4 Log in on the CLI and define a helper

```sh
# Grab the API key
APIKEY=$(lxc exec maas -- maas apikey --username admin)

# Log the CLI profile in (inside the container)
lxc exec maas -- maas login admin http://localhost:5240/MAAS "$APIKEY"

# Convenience wrapper used throughout this doc
MAAS() { lxc exec maas -- maas admin "$@"; }
```

### 3.5 Import the Ubuntu 24.04 boot image (CLI)

```sh
# Select the boot source/selection for noble amd64, then import.
MAAS boot-source-selections create 1 \
  os=ubuntu release=noble arches=amd64 subarches='*' labels='*'

MAAS boot-resources import

# Poll until the resource is present/synced
until MAAS boot-resources read | jq -e '.[] | select(.name=="ubuntu/noble")' >/dev/null; do
  echo "waiting for image sync..."; sleep 20
done
echo "image synced"
```

### 3.6 Add your SSH key (CLI)

Note: generate your ssh key first if needed\!

```sh
MAAS sshkeys create key="$(cat ~/.ssh/id_ed25519.pub)"
```

### 3.7 Configure DHCP on the lab VLAN (CLI)

```sh
# Discover the subnet, fabric and VLAN, plus the rack controller system_id
MAAS subnets read | jq '.[] | {id,cidr,vlan:.vlan.id,fabric:.vlan.fabric_id}'
SUBNET_ID=$(MAAS subnets read | jq -r '.[] | select(.cidr=="10.70.0.0/24") | .id')
FABRIC_ID=$(MAAS subnets read | jq -r '.[] | select(.cidr=="10.70.0.0/24") | .vlan.fabric_id')
VLAN_VID=$(MAAS subnets read | jq -r '.[] | select(.cidr=="10.70.0.0/24") | .vlan.vid')
RACK_ID=$(MAAS rack-controllers read | jq -r '.[0].system_id')

# Dynamic range for PXE/commissioning
MAAS ipranges create type=dynamic start_ip=10.70.0.100 end_ip=10.70.0.200 \
  subnet="$SUBNET_ID" comment="maas-dynamic"

# Turn DHCP on for the VLAN with this rack as primary
MAAS vlan update "$FABRIC_ID" "$VLAN_VID" dhcp_on=true primary_rack="$RACK_ID"
```

### 3.8 DNS upstream (CLI)

```sh
MAAS maas set-config name=upstream_dns value=10.70.0.1
MAAS maas set-config name=dnssec_validation value=no
```

---

## 4\. Register the EC2 host as a LXD VM host in MAAS (CLI)

This is what lets MAAS create and boot any new machine on demand. MAAS reaches the host LXD API across `br-maas` at `10.70.0.1`.

```sh
# Sanity: MAAS container must reach the host LXD API
lxc exec maas -- nc -vz 10.70.0.1 8443

# Register the VM host. Use the trust token from step 2.4.
MAAS vm-hosts create type=lxd \
  power_address=https://10.70.0.1:8443 \
  project=default \
  password=$TOKEN

MAAS vm-hosts read | jq '.[] | {id,name,type}'
VMHOST=$(MAAS vm-hosts read | jq -r '.[0].id')
```

Verify that MAAS is ready to launch VMs:

```sh
lxc exec maas -- maas admin vm-host read "$VMHOST" | jq '.architectures'
```

should show:

```
[
  "amd64/generic"
]
```

### 4.1 Compose the Sunbeam VMs (CLI)

You will probably face resources contention on the VM\_HOST, use this trick:

```sh
MAAS vm-host update $VMHOST cpu_over_commit_ratio=4 memory_over_commit_ratio=2
```

Each composed VM PXE boots, enlists, and commissions automatically.

```sh
for n in 1 2 3; do
  MAAS vm-host compose "$VMHOST" \
    cores=16 memory=32768 \
    storage="root:100,osd:20(ceph)" \
    hostname="sb${n}"
done

# Add a small deployment/jump node
MAAS vm-host compose "$VMHOST" cores=4 memory=6000 storage="root:80" hostname=sbdeploy

# Dedicated Juju controller VMs (HA controller needs its OWN machines, separate
# from the control/compute/storage workers). 3 for HA. These are small: no OSD
# disk and no second NIC, they only run the Juju controller.
for n in 1 2 3; do
  MAAS vm-host compose "$VMHOST" \
    cores=2 memory=4096 \
    storage="root:40" \
    hostname="jc${n}"
done

# Dedicated sunbeam controller VMs (HA controller needs its OWN machines, separate
# from the control/compute/storage workers). 3 for HA. These are small: no OSD
# disk and no second NIC, they only run the Juju controller.
for n in 1 2 3; do
  MAAS vm-host compose "$VMHOST" \
    cores=2 memory=4096 \
    storage="root:40" \
    hostname="sbc${n}"
done

```

Watch them reach `Ready` (commissioning boots ephemeral Ubuntu over PXE, inventories hardware, powers off):

```sh
watch -n 10 'lxc exec maas -- maas admin machines read | \
  jq -r ".[] | select(.hostname|test(\"^(sb|jc)\")) | \"\(.hostname) \(.status_name)\""'
```

#### 4.2 Add the Neutron provider NIC (CLI)

`MAAS vm-host compose` only provisions a **single** NIC (the PXE/management interface, `eth0`). Sunbeam's compute check additionally requires a second, **unconfigured** interface tagged `neutron:physnet1` to carry the external provider network. There is no compose parameter for a second NIC, so it is attached host-side, then MAAS recommissions to inventory it, then it is tagged.

This block is idempotent (safe to re-run):

```sh
PHYSNET_TAG="neutron:physnet1"
NODES="sb1 sb2 sb3"          # storage+compute nodes, NOT sbdeploy
 
# 1. attach a second NIC on br-maas to each VM (VM stopped for a clean attach)
for vm in $NODES; do
  lxc stop "$vm" --force 2>/dev/null || true
  if ! lxc config device show "$vm" | grep -q '^eth1:'; then
    lxc config device add "$vm" eth1 nic nictype=bridged parent=br-maas name=eth1
  fi
  lxc start "$vm"
done
 
# 2. recommission so MAAS inventories the new NIC (and re-confirms the OSD disk)
for vm in $NODES; do
  sysid=$(MAAS machines read | jq -r ".[] | select(.hostname==\"$vm\") | .system_id")
  MAAS machine commission "$sysid"
done
 
# wait for all three back to Ready
watch -n 10 'lxc exec maas -- maas admin machines read | \
  jq -r ".[] | select(.hostname|test(\"^sb[123]$\")) | \"\(.hostname) \(.status_name)\""'
```

Once `Ready`, tag the spare (linkless) interface on each node as the Neutron provider NIC. Leave it unconfigured: the absence of a subnet link is what marks it as the external interface.

```sh
for vm in $NODES; do
  sysid=$(MAAS machines read | jq -r ".[] | select(.hostname==\"$vm\") | .system_id")
  ifid=$(MAAS interfaces read "$sysid" \
    | jq -r '.[] | select((.links|length)==0) | .id' | head -1)
  [ -n "$ifid" ] && MAAS interface update "$sysid" "$ifid" tags="$PHYSNET_TAG"
done
```

Tag the disks:

```sh
for vm in sb1 sb2 sb3; do
  sysid=$(MAAS machines read | jq -r ".[] | select(.hostname==\"$vm\") | .system_id")
  bdid=$(MAAS block-devices read "$sysid" | jq -r '.[] | select(.used_for=="Unused") | .id' | head -1)
  echo "$vm: tagging block-device $bdid ceph"
  MAAS block-device add-tag "$sysid" "$bdid" tag=ceph
done
```

Tag the links:

```sh
for vm in sb1 sb2 sb3; do
  sysid=$(MAAS machines read | jq -r ".[] | select(.hostname==\"$vm\") | .system_id")

  # the second NIC = the non-boot interface; get its id and its link id
  ifid=$(MAAS interfaces read "$sysid" | jq -r '.[] | select(.name=="enp6s0") | .id')
  linkid=$(MAAS interfaces read "$sysid" | jq -r '.[] | select(.name=="enp6s0") | .links[0].id // empty')

  # remove the subnet link so the NIC becomes unconfigured
  [ -n "$linkid" ] && MAAS interface unlink-subnet "$sysid" "$ifid" id="$linkid"

  # tag it as the neutron provider NIC
  MAAS interface update "$sysid" "$ifid" tags="neutron:physnet1"
  echo "$vm: neutron NIC enp6s0 (id $ifid) unlinked + tagged"
done
```

Verify each node has both the `ceph` disk (from compose) and the `neutron` NIC before continuing:

```sh
for vm in $NODES; do
  sysid=$(MAAS machines read | jq -r ".[] | select(.hostname==\"$vm\") | .system_id")
  echo "== $vm =="
  MAAS block-devices read "$sysid" \
    | jq -r '.[] | select(.tags|index("ceph")) | "  ceph disk: \(.name)"'
  MAAS interfaces read "$sysid" \
    | jq -r '.[] | select(.tags|index("neutron:physnet1")) | "  neutron NIC: \(.name)"'
done
```

> **If the `ceph` tag did not survive commissioning** (version-dependent), add it explicitly: find the unused disk and tag it.

```sh
for vm in $NODES; do
  sysid=$(MAAS machines read | jq -r ".[] | select(.hostname==\"$vm\") | .system_id")
  bdid=$(MAAS block-devices read "$sysid" | jq -r '.[] | select(.used_for=="Unused") | .id' | head -1)
  [ -n "$bdid" ] && MAAS block-device add-tag "$sysid" "$bdid" tag=ceph
done
```

### 4.3 Tag machines for Sunbeam roles (CLI)

Role assignment is what Sunbeam's validator and bootstrap use to place functions. Two role families need **dedicated** machines and must not be collocated on the workers:

- **`juju-controller`** \-\> the HA Juju controller. Juju acquires its own dedicated nodes for the controller model. Put this **only** on `jc1/jc2/jc3`.  
- **`control` / `compute` / `storage`** \-\> the OpenStack workers, on `sb1/sb2/sb3`.  
- **`sunbeam`** (infra) \-\> it goes on `sbc1/sbc2/sbc3`.

>   
> **Why dedicated juju controllers?** Tag-only collocation does not make Juju *share* machines across models. Each Juju model (the `controller` model and the `openstack-*` models) acquires its own dedicated nodes per role. Tagging the same 3 VMs as `juju-controller` **and** `control/compute/storage` makes the controller model consume all 3, leaving zero `Ready` machines for the infra/worker models \-\> bootstrap fails with `failed to acquire node: No machine with system ID ... available`.  
>   
> **Why dedicated sunbeam controllers?** According to the reference deployment document that's how it is supposed to be. If you collocate the sunbeam tag with other functions in the end the machine will not be added to the openstack-machines model as everything that is tagged sunbeam is considered infra and belonging to openstack-infra model

```sh
# create all role tags once
for t in control compute storage sunbeam juju-controller openstack-lab; do
  MAAS tags create name="$t" 2>/dev/null || true
done

# workers sb1/sb2/sb3: control + compute + storage + sunbeam (infra collocated)
for vm in sb1 sb2 sb3; do
  sysid=$(MAAS machines read | jq -r ".[] | select(.hostname==\"$vm\") | .system_id")
  for t in control compute storage openstack-lab; do
    MAAS tag update-nodes "$t" add="$sysid"
  done
done

# dedicated juju controllers jc1/jc2/jc3: juju-controller ONLY
for vm in jc1 jc2 jc3; do
  sysid=$(MAAS machines read | jq -r ".[] | select(.hostname==\"$vm\") | .system_id")
  for t in openstack-lab juju-controller; do
    MAAS tag update-nodes $t add="$sysid"
  done
done

# dedicated subeam controllers sbc1/sbc2/sbc3: sunbeam ONLY
for vm in sbc1 sbc2 sbc3; do
  sysid=$(MAAS machines read | jq -r ".[] | select(.hostname==\"$vm\") | .system_id")
  for t in openstack-lab sunbeam; do
    MAAS tag update-nodes $t add="$sysid"
  done
done

```

Confirm the role layout before bootstrapping:

```sh
for vm in sb1 sb2 sb3 jc1 jc2 jc3 sbc1 sbc2 sbc3; do
  sysid=$(MAAS machines read | jq -r ".[] | select(.hostname==\"$vm\") | .system_id")
  echo "$vm: $(MAAS machine read "$sysid" | jq -r '.tag_names | join(",")')"
done
```

Expected: each `sb*` shows `control,compute,storage` (plus auto tags); each `jc*` shows `juju-controller` each `sbc*` show `sunbeam`.

---

## 5\. Deploy the 3-node HA Sunbeam cluster 

Sunbeam with the **MAAS provider** uses MAAS as the bare-metal source. The deployment node (`sbdeploy`) runs the `openstack` snap and orchestrates Juju \+ charms across the 3 machines.

### 5.1 Deploy and SSH to the deployment node

```sh
SBDEPLOY=$(MAAS machines read | jq -r '.[]|select(.hostname=="sbdeploy")|.system_id')
MAAS machine deploy "$SBDEPLOY" distro_series=noble

#wait until state is Deployed
MAAS machines read | jq -r ".[] | select(.hostname|test(\"^(sb|jc)\")) | \"\(.hostname) \(.status_name)\""

SBDEPLOY_IP=$(MAAS machines read | jq -r '.[] | select(.hostname=="sbdeploy") | .ip_addresses[0]')
ssh ubuntu@"$SBDEPLOY_IP"
```

### 5.2 Install the OpenStack (Sunbeam) snap

```sh
sudo snap install openstack --channel=2024.1/stable
snap info openstack    # confirm the track you want; pin it for repeatable demos
sunbeam prepare-node-script --client | bash -x
```

### 5.3 Reserve API VIP ranges in MAAS (CLI, run from the EC2 host)

Range comments must match the `<deployment-name>-internal-api` / `<deployment-name>-public-api` convention Sunbeam expects.

```sh
MAAS ipranges create type=reserved start_ip=10.70.0.210 end_ip=10.70.0.219 \
  subnet="$SUBNET_ID" comment="lab-internal-api"
MAAS ipranges create type=reserved start_ip=10.70.0.220 end_ip=10.70.0.229 \
  subnet="$SUBNET_ID" comment="lab-public-api"
```

### 5.4 Register the MAAS provider with Sunbeam (on sbdeploy)

On the EC2\_HOST: 

```sh
lxc exec maas -- maas apikey --username admin
```

On sbdeploy:

```sh
# API key for the deployment, pulled from the region
MAAS_APIKEY=<from above>

sunbeam deployment add maas lab "$MAAS_APIKEY" http://10.70.0.2:5240/MAAS
```

### 5.4bis Add network space

On the EC2\_HOST

```sh
MAAS spaces create name=sunbeam
MAAS subnet read 10.70.0.0/24 | \
  jq -r '{cidr, vid: .vlan.vid, fabric_id: .vlan.fabric_id, vlan_id: .vlan.id}'
lxc exec maas -- maas admin vlan update <FABRIC_ID> <VID> space=sunbeam
```

On sbdeploy:

```sh
sunbeam deployment space map sunbeam
```

### 5.5 Validate the environment

```sh
sunbeam deployment validate
```

Fix any reported gaps (missing tags, missing reserved ranges, machines not `Deployed`) before bootstrapping.

### 5.6 Bootstrap the HA cluster

On `sbdeploy`:

```sh
sunbeam cluster bootstrap 
sunbeam cluster deploy
```

This will be long, be patient\!

When done this is the status:

```sh
ubuntu@sbdeploy:~$ sunbeam plans list
┏━━━━━━━━━━━━━━━━━━━━━━┳━━━━━━━━┓
┃ Plan                 ┃ Locked ┃
┡━━━━━━━━━━━━━━━━━━━━━━╇━━━━━━━━┩
│ microceph-plan       │        │
│ openstack-plan       │        │
│ hypervisor-plan      │        │
│ k8s-plan             │        │
│ sunbeam-machine-plan │        │
│ cinder-volume-plan   │        │
└──────────────────────┴────────┘
ubuntu@sbdeploy:~$ sunbeam cluster list
            openstack-infra            
┏━━━━━━┳━━━━━━━━━┳━━━━━━━━━┳━━━━━━━━━━┓
┃ Node ┃ Cluster ┃ Machine ┃ Clusterd ┃
┡━━━━━━╇━━━━━━━━━╇━━━━━━━━━╇━━━━━━━━━━┩
│ sbc1 │ ONLINE  │ running │  active  │
│ sbc2 │ ONLINE  │ running │  active  │
│ sbc3 │ ONLINE  │ running │  active  │
└──────┴─────────┴─────────┴──────────┘
                    openstack-machines                    
┏━━━━━━┳━━━━━━━━━┳━━━━━━━━━┳━━━━━━━━━┳━━━━━━━━━┳━━━━━━━━━┓
┃ Node ┃ Machine ┃ Compute ┃ Control ┃ Network ┃ Storage ┃
┡━━━━━━╇━━━━━━━━━╇━━━━━━━━━╇━━━━━━━━━╇━━━━━━━━━╇━━━━━━━━━┩
│ sb1  │ running │ active  │ active  │         │ active  │
│ sb2  │ running │ active  │ active  │         │ active  │
│ sb3  │ running │ active  │ active  │         │ active  │
└──────┴─────────┴─────────┴─────────┴─────────┴─────────┘
ubuntu@sbdeploy:~$ juju status -m openstack-infra
juju status -m openstack-machines
Model            Controller      Cloud/Region  Version  SLA          Timestamp
openstack-infra  lab-controller  lab/default   3.6.23   unsupported  03:22:15Z

App               Version          Status  Scale  Charm                     Channel        Rev  Exposed  Message
sunbeam-clusterd  2024.1/stabl...  active      3  sunbeam-clusterd          2024.1/stable  166  no       
tls-operator                       active      1  self-signed-certificates  1/stable       586  no       

Unit                 Workload  Agent  Machine  Public address  Ports  Message
sunbeam-clusterd/0*  active    idle   0        10.70.0.232            
sunbeam-clusterd/1   active    idle   1        10.70.0.233            
sunbeam-clusterd/2   active    idle   2        10.70.0.234            
tls-operator/0*      active    idle   0        10.70.0.232            

Machine  State    Address      Inst id  Base          AZ       Message
0        started  10.70.0.232  sbc1     ubuntu@24.04  default  Deployed
1        started  10.70.0.233  sbc2     ubuntu@24.04  default  Deployed
2        started  10.70.0.234  sbc3     ubuntu@24.04  default  Deployed
Model               Controller      Cloud/Region  Version  SLA          Timestamp
openstack-machines  lab-controller  lab/default   3.6.23   unsupported  03:22:15Z

SAAS                        Status  Store  URL
cert-distributor            active  local  admin/openstack.cert-distributor
certificate-authority       active  local  admin/openstack.certificate-authority
cinder-volume-mysql-router  active  local  admin/openstack.cinder-volume-mysql-router
keystone-credentials        active  local  admin/openstack.keystone-credentials
keystone-endpoints          active  local  admin/openstack.keystone-endpoints
nova                        active  local  admin/openstack.nova
ovn-relay                   active  local  admin/openstack.ovn-relay
rabbitmq                    active  local  admin/openstack.rabbitmq
traefik-rgw                 active  local  admin/openstack.traefik-rgw

App                   Version  Status  Scale  Charm                 Channel         Rev  Exposed  Message
cinder-volume                  active      3  cinder-volume         2024.1/stable   116  no       
cinder-volume-ceph             active      3  cinder-volume-ceph    2024.1/stable   114  no       
epa-orchestrator               active      3  epa-orchestrator      2024.1/stable    97  no       
k8s                   1.32.13  active      3  k8s                   1.32/stable    1921  no       Ready
microceph                      active      3  microceph             squid/stable    251  no       
openstack-hypervisor           active      3  openstack-hypervisor  2024.1/stable   381  no       
sunbeam-machine                active      3  sunbeam-machine       2024.1/stable   174  no       

Unit                     Workload  Agent  Machine  Public address  Ports     Message
cinder-volume/0*         active    idle   0        10.70.0.235               
  cinder-volume-ceph/2   active    idle            10.70.0.235               
cinder-volume/1          active    idle   1        10.70.0.236               
  cinder-volume-ceph/1   active    idle            10.70.0.236               
cinder-volume/2          active    idle   2        10.70.0.237               
  cinder-volume-ceph/0*  active    idle            10.70.0.237               
k8s/0*                   active    idle   0        10.70.0.235     6443/tcp  Ready
k8s/1                    active    idle   1        10.70.0.236     6443/tcp  Ready
k8s/2                    active    idle   2        10.70.0.237     6443/tcp  Ready
microceph/0*             active    idle   0        10.70.0.235               
microceph/1              active    idle   1        10.70.0.236               
microceph/2              active    idle   2        10.70.0.237               
openstack-hypervisor/0*  active    idle   0        10.70.0.235               
openstack-hypervisor/1   active    idle   1        10.70.0.236               
openstack-hypervisor/2   active    idle   2        10.70.0.237               
sunbeam-machine/0*       active    idle   0        10.70.0.235               
  epa-orchestrator/1     active    idle            10.70.0.235               
sunbeam-machine/1        active    idle   1        10.70.0.236               
  epa-orchestrator/0*    active    idle            10.70.0.236               
sunbeam-machine/2        active    idle   2        10.70.0.237               
  epa-orchestrator/2     active    idle            10.70.0.237               

Machine  State    Address      Inst id  Base          AZ       Message
0        started  10.70.0.235  sb1      ubuntu@24.04  default  Deployed
1        started  10.70.0.236  sb2      ubuntu@24.04  default  Deployed
2        started  10.70.0.237  sb3      ubuntu@24.04  default  Deployed

Offer               Application    Charm          Rev  Connected  Endpoint         Interface        Role
cinder-volume       cinder-volume  cinder-volume  116  1/1        storage-backend  cinder-backend   provider
microceph           microceph      microceph      251  1/1        ceph             ceph-client      provider
microceph-ceph-nfs  microceph      microceph      251  0/0        ceph-nfs         ceph-nfs-client  provider
microceph-ceph-rgw  microceph      microceph      251  0/0        ceph-rgw-ready   ceph-rgw-client  provider
```

### 5.7 Configure and smoke-test

For external sunbeam VM connectivity:

**The physnet1 NIC** on compute nodes must be on a bridge with routable IPs (you already had this: `eth1` on `br-maas`, the `10.70.0.0/24` segment).  
**The external network CIDR** during `sunbeam configure` must match that same L2 segment. So instead of `172.16.2.0/24` (an imaginary range), it must be `10.70.0.0/24` with an allocation pool carved out of the free space (like `10.70.0.231-10.70.0.250`).

On the VM host:

```sh
MAAS ipranges create type=reserved start_ip=10.70.0.231 end_ip=10.70.0.250 comment="openstack-floating-ips"
```

On `sbdeploy`:

```sh
sunbeam cluster list
sunbeam configure --openrc demo-openrc
# configure will ask some questions about the external-network connectivity
# make sure to respond appropriately
# see above
sunbeam launch ubuntu --name smoke-test
# it should give you a ssh command you can use to connect
sunbeam openrc > ~/admin-openrc
sunbeam dashboard-url     # prints the Horizon URL; reach it via SSH tunnel
```

```sh
ubuntu@sbdeploy:~$ ssh -i /home/ubuntu/snap/openstack/1005/sunbeam -o ConnectTimeout=10 ubuntu@10.70.0.231
Welcome to Ubuntu 24.04.4 LTS (GNU/Linux 6.8.0-117-generic x86_64)
 * Documentation:  https://help.ubuntu.com
 * Management:     https://landscape.canonical.com
 * Support:        https://ubuntu.com/pro
 System information as of Wed Jun 17 14:51:55 UTC 2026
  System load:  0.0               Processes:             95
  Usage of /:   59.0% of 2.84GB   Users logged in:       0
  Memory usage: 36%               IPv4 address for ens3: 192.168.0.175
  Swap usage:   0%
Expanded Security Maintenance for Applications is not enabled.
0 updates can be applied immediately.
Enable ESM Apps to receive additional future security updates.
See https://ubuntu.com/esm or run: sudo pro status
The list of available updates is more than a week old.
To check for new updates run: sudo apt update
Failed to connect to https://changelogs.ubuntu.com/meta-release-lts. Check your Internet connection or proxy settings
Last login: Wed Jun 17 14:38:13 2026 from 10.70.0.201
To run a command as administrator (user "root"), use "sudo <command>".
See "man sudo_root" for details.
ubuntu@vmtest1:~$ 

```

---

## 6\. HA Tests 

Save as `sunbeam-tests.sh` on the deployment node (`sbdeploy`). It assumes the MAAS container is reachable for power control; set `MAAS_HOST` to the EC2 host's internal IP so the script can drive MAAS power via SSH.

```sh
victim="sb3"
sysid=$(MAAS machines read | jq -r --arg h "$victim" \
            '.[] | select(.hostname==$h) | .system_id')
echo "Powering OFF $victim ($sysid) via MAAS power control..."
MAAS machine power-off $sysid
lxc list
```

Verify that the status has changed in `sbdeploy`:

```sh
ubuntu@sbdeploy:~$ sunbeam cluster list -f table 
            openstack-infra            
┏━━━━━━┳━━━━━━━━━┳━━━━━━━━━┳━━━━━━━━━━┓
┃ Node ┃ Cluster ┃ Machine ┃ Clusterd ┃
┡━━━━━━╇━━━━━━━━━╇━━━━━━━━━╇━━━━━━━━━━┩
│ sbc1 │ ONLINE  │ running │  active  │
│ sbc2 │ ONLINE  │ running │  active  │
│ sbc3 │ ONLINE  │ running │  active  │
└──────┴─────────┴─────────┴──────────┘
                    openstack-machines                    
┏━━━━━━┳━━━━━━━━━┳━━━━━━━━━┳━━━━━━━━━┳━━━━━━━━━┳━━━━━━━━━┓
┃ Node ┃ Machine ┃ Compute ┃ Control ┃ Network ┃ Storage ┃
┡━━━━━━╇━━━━━━━━━╇━━━━━━━━━╇━━━━━━━━━╇━━━━━━━━━╇━━━━━━━━━┩
│ sb1  │ running │ active  │ active  │         │ active  │
│ sb2  │ running │ active  │ active  │         │ active  │
│ sb3  │ running │ unknown │ unknown │         │ unknown │
└──────┴─────────┴─────────┴─────────┴─────────┴─────────┘

```

If your smoke-test VM was running on sb3 by chance, then you should notice that it is not available anymore also. You can evacuate it and restart it on another sb.

---

## 7\. Additional production-relevant scenarios

- **Rolling reboot** of all 3 nodes one at a time via `MAAS machine power-off` / `power-on`, asserting the API never fully drops.  
- **Ceph OSD removal/return** to show degraded-but-available storage.  
- **Network partition** with `iptables` inside a node VM to validate quorum behavior distinct from clean power-off.  
- **Scale-out**: compose a 4th MAAS VM and `sunbeam cluster add` it live.  
- **Backup/restore** of control-plane state.  
- **Tenant isolation**: two projects with separate networks and quotas.

---

## 8\. Troubleshooting / Important points

- **Machines stuck Commissioning:** confirm DHCP is on the lab VLAN (`MAAS vlan read $FABRIC_ID $VLAN_VID | jq .dhcp_on`) and VMs are bridged to `br-maas`, not `lxdbr0`.  
- **MAAS can't reach LXD:** `lxc exec maas -- nc -vz 10.70.0.1 8443`; recheck the trust token and `core.https_address`.  
- **Sunbeam validate fails on IP ranges:** reserved range comments must match `lab-internal-api` / `lab-public-api`.  
- **Outbound failures in lab VMs:** verify MASQUERADE and `net.ipv4.ip_forward=1` survived reboot (`sudo netfilter-persistent reload`).  
- **Channel drift:** Sunbeam/MAAS move fast. Pin explicit snap channels and re-confirm current `sunbeam` subcommands.  
- When stopping an EC2 instance this will break HA mysqld as the whole mysqld loose quorum at the same time, mysql is not able to restart.


```sh
#at restart
PW=$(juju run mysql/<leader> get-password username=serverconfig -m openstack --format=json | python3 -c 'import sys,json;print(json.load(sys.stdin)["mysql/2"]["results"]["password"])')

juju ssh -m openstack --container mysql mysql/2 \
  "mysqlsh --python serverconfig:$PW@127.0.0.1:3306 -e \"dba.reboot_cluster_from_complete_outage()\""

# also possible:
juju run mysql/<leader> promote-to-primary scope=unit force=true
```

