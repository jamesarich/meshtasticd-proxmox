#!/usr/bin/env bash
# SPDX-FileCopyrightText: Meshtastic contributors
# SPDX-License-Identifier: GPL-3.0-only
#
# Update meshtasticd in place on nodes built from the template.
# Run as root on the Proxmox VE host. See README.md.
set -euo pipefail

usage() {
    cat <<EOF
Usage: $0 [ctid...]

Upgrades meshtasticd from the package repo each node was built with, and restarts it when the version changed.
With no ctid, updates every running container on this host tagged meshtasticd.
EOF
}

die() { echo "$*" >&2; exit 1; }

case "${1:-}" in -h|--help) usage; exit 0 ;; esac
command -v pct >/dev/null || die "pct not found: run this on a Proxmox VE host"
[ "$(id -u)" -eq 0 ] || die "run as root"

if [ $# -gt 0 ]; then
    IDS=("$@")
else
    IDS=()
    for id in $(pct list | awk 'NR > 1 && $2 == "running" { print $1 }'); do
        pct config "$id" | grep -qE '^tags:.*(^|[ ;,])meshtasticd([;, ]|$)' && IDS+=("$id")
    done
    [ ${#IDS[@]} -gt 0 ] || die "no running container tagged meshtasticd; pass ctids instead"
fi

# shellcheck disable=SC2016  # dpkg-query format string
version() { pct exec "$1" -- dpkg-query -W -f '${Version}' meshtasticd 2>/dev/null; }

FAILED=0
for id in "${IDS[@]}"; do
    if ! before=$(version "$id"); then
        echo "CT $id: no meshtasticd package, skipped" >&2
        FAILED=1
        continue
    fi
    # Noninteractive, keeping local config files: a dpkg conffile prompt would hang under pct exec.
    if ! pct exec "$id" -- env DEBIAN_FRONTEND=noninteractive sh -c \
        'apt-get update -qq && apt-get install -qq -y --only-upgrade -o Dpkg::Options::=--force-confold meshtasticd' >/dev/null; then
        echo "CT $id: upgrade failed, still on $before" >&2
        FAILED=1
        continue
    fi
    after=$(version "$id")
    if [ "$before" = "$after" ]; then
        echo "CT $id: $after, already current"
    else
        pct exec "$id" -- systemctl restart meshtasticd
        echo "CT $id: $before -> $after, restarted"
    fi
done
exit "$FAILED"
