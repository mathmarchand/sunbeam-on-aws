#!/usr/bin/env bash
# Runs on sbdeploy as "ubuntu" (instruction.md 5.2, 5.4, 5.4bis, 5.5):
#   - install the openstack snap and prepare the node as a client,
#   - register the MAAS deployment,
#   - map the network space,
#   - validate.
# The long-running steps (cluster bootstrap/deploy, configure) are left to you.
# Idempotent: safe to re-run.
set -euo pipefail
# shellcheck source=/dev/null
source "$HOME/.config/sunbeam-lab/lab.env"

log() { echo "==> [sbdeploy] $*"; }
# prepare-node-script adds ubuntu to snap_daemon; this session isn't in the
# group yet, so run sunbeam through sg.
sb() { sg snap_daemon -c "$(printf '%q ' sunbeam "$@")"; }

log "waiting for cloud-init"
cloud-init status --wait >/dev/null 2>&1 || true

log "openstack snap (${OPENSTACK_CHANNEL})"
if snap list openstack >/dev/null 2>&1; then
  sudo snap refresh openstack --channel="$OPENSTACK_CHANNEL" || true
else
  sudo snap install openstack --channel="$OPENSTACK_CHANNEL"
fi

log "prepare-node-script --client"
sunbeam prepare-node-script --client | bash -x

if sb deployment list 2>/dev/null | grep -qw -- "$DEPLOYMENT"; then
  log "deployment ${DEPLOYMENT} already registered; switching to it"
  sb deployment switch "$DEPLOYMENT"
else
  log "registering MAAS deployment ${DEPLOYMENT} -> ${MAAS_URL}"
  sb deployment add maas "$DEPLOYMENT" "$MAAS_API_KEY" "$MAAS_URL"
fi

log "mapping space ${SPACE}"
sb deployment space map "$SPACE"

log "validating"
if sb deployment validate; then
  log "validation OK"
else
  echo "WARNING: 'sunbeam deployment validate' reported issues; review them before bootstrapping." >&2
fi

cat <<EOF

Next steps on sbdeploy (long running):
  sunbeam cluster bootstrap --manifest ~/manifest.yaml
  sunbeam cluster deploy
  sunbeam configure --openrc ~/demo-openrc
  sunbeam openrc > ~/admin-openrc
EOF
