#!/usr/bin/env bash
# SPDX-FileCopyrightText: Meshtastic contributors
# SPDX-License-Identifier: GPL-3.0-only
#
# Build a Proxmox VE container template running a radio-less meshtasticd node.
# Run as root on a Proxmox VE host. See README.md.
set -euo pipefail

CTID=""
STORAGE="local-lvm"
TEMPLATE_STORAGE="local"
BRIDGE="vmbr0"
CHANNEL="beta"
CT_HOSTNAME="meshtasticd"

usage() {
    cat <<EOF
Usage: $0 [options]

  --id <ctid>                 container ID (default: next free ID)
  --storage <name>            rootfs storage (default: $STORAGE)
  --template-storage <name>   storage holding the Debian image (default: $TEMPLATE_STORAGE)
  --bridge <name>             network bridge (default: $BRIDGE)
  --channel <beta|alpha|daily>  meshtasticd package channel (default: $CHANNEL)
  --hostname <name>           container hostname (default: $CT_HOSTNAME)
EOF
}

log() { printf '\n==> %s\n' "$*"; }
die() { echo "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
    case "$1" in
        --id) CTID="$2"; shift 2 ;;
        --storage) STORAGE="$2"; shift 2 ;;
        --template-storage) TEMPLATE_STORAGE="$2"; shift 2 ;;
        --bridge) BRIDGE="$2"; shift 2 ;;
        --channel) CHANNEL="$2"; shift 2 ;;
        --hostname) CT_HOSTNAME="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
done

case "$CHANNEL" in beta|alpha|daily) ;; *) echo "--channel must be beta, alpha or daily" >&2; exit 2 ;; esac
command -v pct >/dev/null || die "pct not found: run this on a Proxmox VE host"
[ "$(id -u)" -eq 0 ] || die "run as root"
FILES="$(cd "$(dirname "$0")" && pwd)/files"
for f in sim.yaml meshtasticd-wait-online.conf ssh-regen-hostkeys.conf; do
    [ -f "$FILES/$f" ] || die "missing $FILES/$f"
done
[ -n "$CTID" ] || CTID=$(pvesh get /cluster/nextid)
if pct status "$CTID" >/dev/null 2>&1; then
    die "CT $CTID already exists"
fi

CREATED=0
on_exit() {
    status=$?
    if [ "$status" -ne 0 ] && [ "$CREATED" -eq 1 ]; then
        echo "build failed; CT $CTID is left for inspection (pct enter $CTID)." >&2
        echo "remove it with: pct destroy $CTID --purge --force" >&2
    fi
}
trap on_exit EXIT

log "Finding the Debian 13 container image"
pveam update >/dev/null
IMAGE=$(pveam available --section system | awk '$2 ~ /^debian-13-standard_.*_amd64\.tar\.zst$/ {print $2}' | sort -V | tail -1)
[ -n "$IMAGE" ] || die "no debian-13-standard image in pveam available"
if ! pveam list "$TEMPLATE_STORAGE" | grep -qF -- "$IMAGE"; then
    pveam download "$TEMPLATE_STORAGE" "$IMAGE"
fi

log "Creating CT $CTID from $IMAGE"
pct create "$CTID" "$TEMPLATE_STORAGE:vztmpl/$IMAGE" \
    --hostname "$CT_HOSTNAME" \
    --cores 1 --memory 512 --swap 256 \
    --rootfs "$STORAGE:4" \
    --net0 "name=eth0,bridge=$BRIDGE,ip=dhcp,type=veth" \
    --unprivileged 1 --features nesting=1 \
    --ostype debian --onboot 0 \
    --description "meshtasticd ($CHANNEL) radio-less node template. Clone, start, then set the region: meshtastic --host <ip> --set lora.region <REGION>"
CREATED=1
pct start "$CTID"

log "Waiting for the container's network"
wait_for_eth0() {
    for _ in $(seq 60); do
        pct exec "$CTID" -- sh -c 'ip -4 -o addr show dev eth0 scope global | grep -q inet' && return 0
        sleep 1
    done
    return 1
}
wait_for_eth0 || die "eth0 got no IPv4 address in 60 s; check DHCP on $BRIDGE"

log "Installing meshtasticd from network:Meshtastic:$CHANNEL"
# shellcheck disable=SC2016  # expands inside the container
pct exec "$CTID" -- env LC_ALL=C CHANNEL="$CHANNEL" bash -euo pipefail -c '
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq curl gpg ca-certificates >/dev/null
REPO="https://download.opensuse.org/repositories/network:/Meshtastic:/$CHANNEL/Debian_13"
install -d -m 0755 /etc/apt/keyrings
curl -fsSL "$REPO/Release.key" | gpg --dearmor -o /etc/apt/keyrings/meshtastic.gpg
echo "deb [signed-by=/etc/apt/keyrings/meshtastic.gpg] $REPO/ /" > /etc/apt/sources.list.d/meshtastic.list
apt-get update -qq
apt-get install -y -qq meshtasticd >/dev/null
systemctl stop meshtasticd
'

log "Configuring the node"
pct exec "$CTID" -- mkdir -p /etc/systemd/system/meshtasticd.service.d /etc/systemd/system/ssh.service.d
pct push "$CTID" "$FILES/sim.yaml" /etc/meshtasticd/config.d/sim.yaml --perms 0644
pct push "$CTID" "$FILES/meshtasticd-wait-online.conf" /etc/systemd/system/meshtasticd.service.d/wait-online.conf --perms 0644
pct push "$CTID" "$FILES/ssh-regen-hostkeys.conf" /etc/systemd/system/ssh.service.d/regen-hostkeys.conf --perms 0644
pct exec "$CTID" -- chown meshtasticd:meshtasticd /etc/meshtasticd/config.d/sim.yaml
pct exec "$CTID" -- systemctl enable meshtasticd

log "Removing per-node identity so every clone starts fresh"
pct exec "$CTID" -- bash -euo pipefail -c '
rm -rf /var/lib/meshtasticd/.portduino
rm -f /etc/ssh/ssh_host_*
truncate -s 0 /etc/machine-id
rm -f /var/lib/dbus/machine-id /var/lib/dhcp/*.leases
apt-get clean
journalctl --rotate -q; journalctl --vacuum-time=1s -q
rm -f /root/.bash_history
'
# shellcheck disable=SC2016  # dpkg-query format string
VERSION=$(pct exec "$CTID" -- dpkg-query -W -f '${Version}' meshtasticd)

pct shutdown "$CTID"
pct template "$CTID"

cat <<EOF

CT $CTID is a template with meshtasticd $VERSION.

New node:
  pct clone $CTID <newid> --full --hostname mesh-<name>
  pct start <newid>
  meshtastic --host <ip> --set lora.region <REGION>
EOF
