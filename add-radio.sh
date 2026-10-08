#!/usr/bin/env bash
# SPDX-FileCopyrightText: Meshtastic contributors
# SPDX-License-Identifier: GPL-3.0-only
#
# Turn a clone of the template into an on-air node driving a CH341 USB LoRa board.
# Run as root on the Proxmox VE host the board is plugged into. See README.md.
set -euo pipefail

BOARD="lora-usb-meshstick-1262.yaml"
SERIAL=""
CTID=""

usage() {
    cat <<EOF
Usage: $0 <ctid> [options]

  --board <file>     board config from /etc/meshtasticd/available.d (default: $BOARD)
  --serial <serial>  USB serial number, to pick one board when several are plugged in
EOF
}

die() { echo "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
    case "$1" in
        --board) BOARD="$2"; shift 2 ;;
        --serial) SERIAL="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        -*) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
        *) [ -z "$CTID" ] || die "only one ctid"; CTID="$1"; shift ;;
    esac
done

[ -n "$CTID" ] || { usage >&2; exit 2; }
command -v pct >/dev/null || die "pct not found: run this on a Proxmox VE host"
[ "$(id -u)" -eq 0 ] || die "run as root"
CONF="/etc/pve/lxc/$CTID.conf"
[ -f "$CONF" ] || die "CT $CTID does not exist"
! grep -q '^template: 1' "$CONF" || die "CT $CTID is a template; clone it first"
case "$BOARD" in */*|"") die "--board takes a file name from available.d" ;; esac
case "$SERIAL" in *[!A-Za-z0-9._-]*) die "--serial takes letters, digits, '.', '_' and '-'" ;; esac

# meshtasticd drives CH341 boards through libusb, so the container needs the raw USB node
# and the container's meshtasticd user must be able to open it. Same rule meshtasticd ships.
RULE=/etc/udev/rules.d/99-meshtasticd-ch341.rules
if [ ! -f "$RULE" ]; then
    echo 'SUBSYSTEM=="usb", ATTRS{idVendor}=="1a86", ATTRS{idProduct}=="5512", MODE="0666"' > "$RULE"
    udevadm control --reload-rules
    udevadm trigger --subsystem-match=usb --attr-match=idVendor=1a86
fi

# Lines after a [section] header belong to a snapshot or to pending changes, not the live config.
conf_add() {
    awk -v line="$1" '/^\[/ { exit } $0 == line { found = 1; exit } END { exit !found }' "$CONF" && return 0
    awk -v line="$1" '!done && /^\[/ { print line; done = 1 } { print } END { if (!done) print line }' \
        "$CONF" > "$CONF.tmp.$$"
    mv "$CONF.tmp.$$" "$CONF"
}
# Bind all of /dev/bus/usb so the board survives a replug, which renumbers its node.
conf_add 'lxc.cgroup2.devices.allow: c 189:* rwm'
conf_add 'lxc.mount.entry: /dev/bus/usb dev/bus/usb none bind,optional,create=dir'

if [ "$(pct status "$CTID" | awk '{print $2}')" = running ]; then
    pct reboot "$CTID"
else
    pct start "$CTID"
fi
wait_for_ct() {
    for _ in $(seq 30); do
        pct exec "$CTID" -- test -d /etc/meshtasticd/available.d 2>/dev/null && return 0
        sleep 1
    done
    return 1
}
wait_for_ct || die "CT $CTID did not come up with meshtasticd in 30 s; is it a clone of the template?"

# shellcheck disable=SC2016  # expands inside the container
pct exec "$CTID" -- env BOARD="$BOARD" SERIAL="$SERIAL" bash -euo pipefail -c '
SRC="/etc/meshtasticd/available.d/$BOARD"
CONFD=/etc/meshtasticd/config.d
[ -f "$SRC" ] || { echo "no $SRC; boards: $(ls /etc/meshtasticd/available.d | tr "\n" " ")" >&2; exit 1; }
if [ -n "$SERIAL" ]; then
    # Replace any USB_Serialnum line, set or commented out, with ours right under Lora: so it stays in that section.
    awk -v line="  USB_Serialnum: $SERIAL" \
        "/^[ #]*USB_Serialnum:/ { next } { print } /^Lora:/ { print line; done = 1 } END { exit !done }" \
        "$SRC" > "$CONFD/radio.yaml.new" || { rm -f "$CONFD/radio.yaml.new"; echo "no Lora section in $BOARD" >&2; exit 1; }
else
    cp "$SRC" "$CONFD/radio.yaml.new"
fi
mv "$CONFD/radio.yaml.new" "$CONFD/radio.yaml"
rm -f "$CONFD/sim.yaml"
cat > "$CONFD/node.yaml" <<EOF
# Node ID from the eth0 MAC, unique per clone. UDP stays off so simulated nodes are not bridged on air.
General:
  MACAddressSource: eth0
EOF
chown meshtasticd:meshtasticd "$CONFD/radio.yaml" "$CONFD/node.yaml"
systemctl restart meshtasticd
'

cat <<EOF
CT $CTID now drives $BOARD${SERIAL:+ (serial $SERIAL)}.
Check it: pct exec $CTID -- journalctl -u meshtasticd -n 50
Then set the region before it transmits: meshtastic --host <ip> --set lora.region <REGION>
EOF
