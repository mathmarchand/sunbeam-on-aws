#!/usr/bin/env bash
# Section 3.1 - 3.4 of instruction.md: MAAS region+rack in an LXD container.
# Everything after "the API is up" (images, DHCP, DNS, VM host, machines) is
# done with the Terraform MAAS provider in the maas-config module.
# Idempotent: safe to re-run.
set -euo pipefail
# shellcheck source=/dev/null
source /tmp/sunbeam-lab/lab.env

log() { echo "==> [maas] $*"; }
in_maas() { lxc exec maas -- "$@"; }

wait_for() { # wait_for <timeout_s> <description> <cmd...>
  local timeout=$1 what=$2; shift 2
  local end=$((SECONDS + timeout))
  until "$@" >/dev/null 2>&1; do
    if [ $SECONDS -ge $end ]; then echo "FATAL: timed out waiting for ${what}" >&2; return 1; fi
    sleep 5
  done
}

if ! lxc info maas >/dev/null 2>&1; then
  log "launching container maas (ubuntu:24.04)"
  lxc launch ubuntu:24.04 maas
fi
lxc start maas 2>/dev/null || true
wait_for 300 "maas container" in_maas true
in_maas cloud-init status --wait >/dev/null 2>&1 || true

log "pinning ${MAAS_IP}/${LAB_PREFIX} on eth0"
# dhcp4: false matters: once MAAS DHCP is on, the cloud-init DHCP config would
# otherwise give the container a second (dynamic) address.
in_maas bash -c "
set -e
cat >/etc/cloud/cloud.cfg.d/99-disable-network-config.cfg <<'EOF'
network: {config: disabled}
EOF
rm -f /etc/netplan/50-cloud-init.yaml
cat >/etc/netplan/60-maas.yaml <<EOF
network:
  version: 2
  ethernets:
    eth0:
      dhcp4: false
      dhcp6: false
      addresses: [${MAAS_IP}/${LAB_PREFIX}]
      routes:
        - to: default
          via: ${LAB_GATEWAY}
      nameservers:
        addresses: [${LAB_GATEWAY}, 8.8.8.8]
EOF
chmod 600 /etc/netplan/60-maas.yaml
netplan apply
"
wait_for 300 "internet access from the maas container" in_maas ping -c1 -W2 8.8.8.8
wait_for 120 "DNS from the maas container" in_maas getent hosts api.snapcraft.io

log "installing maas ${MAAS_CHANNEL} + maas-test-db"
if in_maas snap list maas >/dev/null 2>&1; then
  in_maas snap refresh maas --channel="$MAAS_CHANNEL" || true
else
  in_maas snap install maas --channel="$MAAS_CHANNEL"
fi
in_maas snap list maas-test-db >/dev/null 2>&1 || in_maas snap install maas-test-db

if [ "$(in_maas cat /var/snap/maas/common/snap_mode 2>/dev/null || echo none)" = "none" ]; then
  log "maas init region+rack"
  in_maas maas init region+rack \
    --maas-url "http://${MAAS_IP}:5240/MAAS" \
    --database-uri maas-test-db:/// </dev/null
fi
wait_for 600 "MAAS API" curl -fsS "http://${MAAS_IP}:5240/MAAS/api/2.0/version/"

if ! in_maas maas apikey --username "$MAAS_ADMIN_USER" >/dev/null 2>&1; then
  log "creating admin ${MAAS_ADMIN_USER}"
  in_maas maas createadmin \
    --username "$MAAS_ADMIN_USER" \
    --password "$MAAS_ADMIN_PASSWORD" \
    --email "$MAAS_ADMIN_EMAIL" </dev/null
fi

APIKEY=$(in_maas maas apikey --username "$MAAS_ADMIN_USER" | head -n1)
in_maas maas login admin http://localhost:5240/MAAS/ "$APIKEY" >/dev/null
log "CLI profile 'admin' logged in (use: lxc exec maas -- maas admin ...)"

# The Terraform maas-config unit reads these with data sources at plan time,
# so do not finish before the rack registered and discovered the lab subnet.
log "waiting for the rack controller and the ${LAB_CIDR} subnet"
wait_for 600 "rack controller" bash -c "lxc exec maas -- maas admin rack-controllers read | jq -e 'length > 0'"
wait_for 600 "subnet ${LAB_CIDR}" bash -c \
  "lxc exec maas -- maas admin subnets read | jq -e --arg c '${LAB_CIDR}' 'any(.[]; .cidr == \$c)'"

# Convenience wrapper on the host for the ubuntu user.
cat >/etc/profile.d/maas-lab.sh <<'EOF'
MAAS() { lxc exec maas -- maas admin "$@"; }
EOF

log "done"
