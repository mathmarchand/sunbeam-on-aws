#!/usr/bin/env bash
# Section 4.2 of instruction.md, run on the EC2 host:
#   - attach a 2nd NIC (on the lab bridge) to each worker VM,
#   - recommission so MAAS inventories it,
#   - unlink + tag that NIC as the Neutron provider NIC,
#   - tag the non-boot disk for Ceph.
# There is no compose/provider parameter for any of this, hence the script.
#
# Idempotent and safe: only machines in "Ready" are modified; machines that are
# already configured are left alone (whatever their state).
#
# Usage: configure-workers.sh "<node> <node> ..." <physnet_tag> <ceph_tag> <bridge>
set -euo pipefail
NODES=$1 PHYSNET_TAG=$2 CEPH_TAG=$3 BRIDGE=$4
TIMEOUT=${COMMISSION_TIMEOUT:-3600}

MAAS() { lxc exec maas -- maas admin "$@"; }
log() { echo "==> [workers] $*"; }

sysid_of() {
  MAAS machines read hostname="$1" | jq -r '.[0].system_id // empty'
}
status_of() {
  MAAS machine read "$1" | jq -r '.status_name'
}
# Interfaces other than the boot (PXE) one.
extra_ifaces() {
  local sid=$1 boot
  boot=$(MAAS machine read "$sid" | jq -r '.boot_interface.id')
  MAAS interfaces read "$sid" | jq -c --argjson boot "$boot" \
    '[.[] | select(.id != $boot and .type == "physical")]'
}
# Physical disks other than the boot disk.
extra_disks() {
  local sid=$1 boot
  boot=$(MAAS machine read "$sid" | jq -r '.boot_disk.id // -1')
  MAAS block-devices read "$sid" | jq -c --argjson boot "$boot" \
    '[.[] | select(.id != $boot and .type == "physical")]'
}

wait_ready() {
  local sid=$1 name=$2 end=$((SECONDS + TIMEOUT)) st
  while :; do
    st=$(status_of "$sid")
    case "$st" in
      Ready) log "$name is Ready"; return 0 ;;
      Failed*) echo "FATAL: $name is '$st'" >&2; return 1 ;;
    esac
    if [ $SECONDS -ge $end ]; then echo "FATAL: timeout waiting for $name (status: $st)" >&2; return 1; fi
    sleep 15
  done
}

declare -A SID
to_commission=()

# 1. attach the second NIC (VMs in Ready are powered off by MAAS).
for vm in $NODES; do
  sid=$(sysid_of "$vm")
  [ -n "$sid" ] || { echo "FATAL: machine $vm not found in MAAS" >&2; exit 1; }
  SID[$vm]=$sid

  if [ "$(extra_ifaces "$sid" | jq 'length')" -ge 1 ]; then
    log "$vm already has a provider NIC inventoried"
    continue
  fi
  st=$(status_of "$sid")
  if [ "$st" != "Ready" ]; then
    echo "WARNING: $vm has no second NIC but is '$st'; skipping (only Ready machines are modified)" >&2
    continue
  fi

  if ! lxc config device show "$vm" | grep -q '^eth1:'; then
    log "$vm: attaching eth1 on $BRIDGE"
    lxc stop "$vm" --force 2>/dev/null || true
    lxc config device add "$vm" eth1 nic nictype=bridged parent="$BRIDGE" name=eth1
  fi
  to_commission+=("$vm")
done

# 2. recommission (in parallel) so MAAS inventories the new NIC.
for vm in "${to_commission[@]}"; do
  log "$vm: commissioning"
  MAAS machine commission "${SID[$vm]}" testing_scripts=none >/dev/null
done
for vm in "${to_commission[@]}"; do
  wait_ready "${SID[$vm]}" "$vm"
done

# 3. neutron provider NIC: no subnet link + tag; 4. ceph disk tag.
for vm in $NODES; do
  sid=${SID[$vm]}
  st=$(status_of "$sid")

  ifaces=$(extra_ifaces "$sid")
  if [ "$(jq 'length' <<<"$ifaces")" -eq 0 ]; then
    echo "WARNING: $vm has no provider NIC; Sunbeam validation will fail for it" >&2
  else
    iface=$(jq -c '.[0]' <<<"$ifaces")
    ifid=$(jq -r '.id' <<<"$iface")
    ifname=$(jq -r '.name' <<<"$iface")
    if jq -e --arg t "$PHYSNET_TAG" '(.tags | index($t)) and ((.links | length) == 0)' <<<"$iface" >/dev/null; then
      log "$vm: $ifname already unconfigured + tagged $PHYSNET_TAG"
    elif [ "$st" != "Ready" ]; then
      echo "WARNING: $vm is '$st'; not touching $ifname" >&2
    else
      for linkid in $(jq -r '.links[].id' <<<"$iface"); do
        MAAS interface unlink-subnet "$sid" "$ifid" id="$linkid" >/dev/null
      done
      tags=$(jq -r --arg t "$PHYSNET_TAG" '(.tags + [$t]) | unique | join(",")' <<<"$iface")
      MAAS interface update "$sid" "$ifid" tags="$tags" >/dev/null
      log "$vm: $ifname (id $ifid) unlinked + tagged $PHYSNET_TAG"
    fi
  fi

  disks=$(extra_disks "$sid")
  if [ "$(jq 'length' <<<"$disks")" -eq 0 ]; then
    echo "WARNING: $vm has no extra disk for Ceph" >&2
  elif jq -e --arg t "$CEPH_TAG" 'any(.[]; .tags | index($t))' <<<"$disks" >/dev/null; then
    log "$vm: ceph disk already tagged"
  elif [ "$st" != "Ready" ]; then
    echo "WARNING: $vm is '$st'; not tagging its ceph disk" >&2
  else
    bd=$(jq -c 'sort_by(.size) | .[0]' <<<"$disks")
    MAAS block-device add-tag "$sid" "$(jq -r '.id' <<<"$bd")" tag="$CEPH_TAG" >/dev/null
    log "$vm: block device $(jq -r '.name' <<<"$bd") tagged $CEPH_TAG"
  fi
done

# Summary (same check as instruction.md).
for vm in $NODES; do
  sid=${SID[$vm]}
  echo "== $vm =="
  MAAS block-devices read "$sid" | jq -r --arg t "$CEPH_TAG" '.[] | select(.tags | index($t)) | "  ceph disk:   \(.name)"'
  MAAS interfaces read "$sid" | jq -r --arg t "$PHYSNET_TAG" '.[] | select(.tags | index($t)) | "  neutron NIC: \(.name)"'
done
