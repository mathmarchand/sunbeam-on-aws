#!/usr/bin/env bash
# Runs LOCALLY (Terraform "external" data source). Fetches the MAAS admin API
# key from the container over SSH and prints {"api_key": "..."}.
# Usage: get-apikey.sh <host> <ssh_user> <private_key_file> <maas_user>
set -euo pipefail
host=$1 user=$2 key=$3 maas_user=$4

apikey=$(ssh -i "$key" \
  -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
  -o LogLevel=ERROR -o ConnectTimeout=20 \
  "${user}@${host}" \
  "sudo lxc exec maas -- maas apikey --username '${maas_user}'" | head -n1 | tr -d '[:space:]')

if ! [[ "$apikey" =~ ^[A-Za-z0-9]+:[A-Za-z0-9]+:[A-Za-z0-9]+$ ]]; then
  echo "unexpected MAAS API key format from ${host}" >&2
  exit 1
fi
printf '{"api_key":"%s"}\n' "$apikey"
