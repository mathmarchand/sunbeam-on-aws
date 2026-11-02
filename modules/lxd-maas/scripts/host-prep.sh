#!/usr/bin/env bash
# Section 1 of instruction.md: base packages, KVM check, br-maas bridge, NAT.
# Idempotent: safe to re-run.
set -euo pipefail
# shellcheck source=/dev/null
source /tmp/sunbeam-lab/lab.env
export DEBIAN_FRONTEND=noninteractive

log() { echo "==> [host-prep] $*"; }

log "waiting for cloud-init"
cloud-init status --wait >/dev/null 2>&1 || true

log "base packages"
echo "iptables-persistent iptables-persistent/autosave_v4 boolean true" | debconf-set-selections
echo "iptables-persistent iptables-persistent/autosave_v6 boolean true" | debconf-set-selections
apt-get update -q
apt-get -y -q -o Dpkg::Options::=--force-confold -o Dpkg::Options::=--force-confdef full-upgrade
apt-get -y -q install jq git make bridge-utils cpu-checker virtinst netcat-openbsd iptables-persistent

log "checking nested virtualization"
if ! kvm-ok || [ ! -e /dev/kvm ]; then
  echo "FATAL: /dev/kvm is not available. The instance must be an m8i/c8i/r8i (or .metal)" >&2
  echo "       started with cpu_options.nested_virtualization=enabled." >&2
  exit 1
fi

log "lab bridge br-maas (${LAB_GATEWAY}/${LAB_PREFIX})"
cat >/etc/netplan/99-maas-lab.yaml <<EOF
network:
  version: 2
  bridges:
    br-maas:
      addresses: [${LAB_GATEWAY}/${LAB_PREFIX}]
      dhcp4: false
      dhcp6: false
EOF
chmod 600 /etc/netplan/99-maas-lab.yaml
netplan apply
for _ in $(seq 1 30); do
  ip -4 addr show br-maas | grep -q "inet ${LAB_GATEWAY}/" && break
  sleep 2
done
ip -4 addr show br-maas | grep -q "inet ${LAB_GATEWAY}/" || { echo "FATAL: br-maas has no address" >&2; exit 1; }

# MAAS uses ${LAB_GATEWAY} as its upstream DNS (instruction.md 3.8), but
# systemd-resolved only listens on 127.0.0.53 by default. Add a stub
# listener on the bridge address so that upstream actually answers.
log "DNS stub listener on ${LAB_GATEWAY}"
mkdir -p /etc/systemd/resolved.conf.d
cat >/etc/systemd/resolved.conf.d/99-maas-lab.conf <<EOF
[Resolve]
DNSStubListenerExtra=${LAB_GATEWAY}
EOF
systemctl restart systemd-resolved

log "IP forwarding + NAT"
echo "net.ipv4.ip_forward=1" >/etc/sysctl.d/99-maas-forward.conf
sysctl -q --system

PRIMARY_IF=$(ip route | awk '/^default/ {print $5; exit}')
ensure() { # ensure <table> <chain> <rule...>
  local table=$1; shift
  iptables -t "$table" -C "$@" 2>/dev/null || iptables -t "$table" -A "$@"
}
ensure nat    POSTROUTING -s "$LAB_CIDR" -o "$PRIMARY_IF" -j MASQUERADE
ensure filter FORWARD -s "$LAB_CIDR" -j ACCEPT
ensure filter FORWARD -d "$LAB_CIDR" -m state --state ESTABLISHED,RELATED -j ACCEPT

if [ "${EXPOSE_MAAS_API}" = "true" ]; then
  log "DNAT ${PRIMARY_IF}:5240 -> ${MAAS_IP}:5240 (MAAS API for Terraform)"
  ensure nat    PREROUTING -i "$PRIMARY_IF" -p tcp --dport 5240 -j DNAT --to-destination "${MAAS_IP}:5240"
  ensure filter FORWARD -d "$MAAS_IP" -p tcp --dport 5240 -m conntrack --ctstate NEW -j ACCEPT
fi
netfilter-persistent save

log "lab SSH key for ubuntu (hop from the host to any lab VM)"
install -d -m 700 -o ubuntu -g ubuntu /home/ubuntu/.ssh
install -m 600 -o ubuntu -g ubuntu /tmp/sunbeam-lab/id_lab /home/ubuntu/.ssh/id_ed25519
install -m 644 -o ubuntu -g ubuntu /tmp/sunbeam-lab/id_lab.pub /home/ubuntu/.ssh/id_ed25519.pub
rm -f /tmp/sunbeam-lab/id_lab

log "done"
