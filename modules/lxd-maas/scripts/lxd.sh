#!/usr/bin/env bash
# Section 2 of instruction.md: LXD 5.21 (MAAS is not compatible with LXD 6),
# ZFS storage, default profile on br-maas, API exposed on :8443.
# Idempotent: safe to re-run.
set -euo pipefail
# shellcheck source=/dev/null
source /tmp/sunbeam-lab/lab.env
export DEBIAN_FRONTEND=noninteractive

log() { echo "==> [lxd] $*"; }

log "removing deb-based lxd/lxc (if any)"
apt-get -y -q purge lxd lxd-client lxd-installer lxc lxc-utils liblxc1 2>/dev/null || true
apt-get -y -q autoremove

tracking=$(snap list lxd 2>/dev/null | awk 'NR==2 {print $4}' || true)
if [ -z "$tracking" ]; then
  log "installing lxd ${LXD_CHANNEL}"
  snap install lxd --channel="$LXD_CHANNEL"
elif [ "${tracking%%/*}" != "${LXD_CHANNEL%%/*}" ]; then
  if lxc storage show default >/dev/null 2>&1; then
    echo "FATAL: lxd snap tracks '${tracking}' and is already initialized; refusing to downgrade to ${LXD_CHANNEL}." >&2
    exit 1
  fi
  log "lxd tracks ${tracking}; reinstalling from ${LXD_CHANNEL}"
  snap remove --purge lxd
  snap install lxd --channel="$LXD_CHANNEL"
else
  snap refresh lxd --channel="$LXD_CHANNEL" || true
fi
lxd waitready --timeout=300
usermod -aG lxd ubuntu

if ! lxc storage show default >/dev/null 2>&1; then
  log "lxd init (zfs loop ${LXD_STORAGE_GB}GB, API on [::]:8443)"
  lxd init --auto \
    --storage-backend=zfs \
    --storage-create-loop="$LXD_STORAGE_GB" \
    --network-address='[::]' \
    --network-port=8443
fi

log "default profile eth0 -> br-maas"
if [ "$(lxc profile device get default eth0 parent 2>/dev/null || true)" != "br-maas" ]; then
  lxc profile device remove default eth0 2>/dev/null || true
  lxc profile device add default eth0 nic nictype=bridged parent=br-maas name=eth0
fi

log "neutralizing lxdbr0 DHCP/DNS (MAAS owns DHCP)"
if lxc network show lxdbr0 >/dev/null 2>&1; then
  lxc network set lxdbr0 ipv4.dhcp=false
  lxc network set lxdbr0 ipv6.dhcp=false
  lxc network set lxdbr0 dns.mode=none
fi

lxc config set core.https_address '[::]:8443'
log "done"
