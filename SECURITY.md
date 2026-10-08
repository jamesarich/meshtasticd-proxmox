# Security Policy

## Reporting a vulnerability

Please report security issues privately through GitHub Security Advisories (<https://github.com/jamesarich/meshtasticd-proxmox/security/advisories/new>) rather than a public issue. We aim to acknowledge within a few days.

## Threat model

Both scripts run as root on the Proxmox VE host. The template is an unprivileged container with `nesting=1`, which systemd inside it uses to isolate services and which Proxmox documents as exposing procfs and sysfs to the guest.

- **Packages come from the Meshtastic OBS repository** over HTTPS, and apt checks them against its `Release.key`. The key is fetched from the same server during each build, so trust in the template rests on `download.opensuse.org`.
- **A node's TCP API on port 4403 has no authentication.** Anyone who can reach the container on the network can read its messages, change its config and send as it. Keep nodes on a trusted LAN or firewall the port.
- **`add-radio.sh` widens USB access.** Its udev rule makes every CH341 board (`1a86:5512`) on the host readable and writable by any local user, the same rule meshtasticd ships. The container gets `/dev/bus/usb` and the USB character device class (`c 189:*`); host permissions still apply. The container can read every USB device's descriptors (host nodes are usually world-readable), but it can drive only world-writable nodes, which with this rule means CH341 boards.
- **Simulated nodes broadcast on the LAN.** UDP multicast traffic is readable by anything on the segment, as with any meshtasticd node using UDP.

## Out of scope

Proxmox VE and LXC isolation themselves, and mesh-layer or firmware issues in meshtasticd (see [meshtastic/firmware](https://github.com/meshtastic/firmware)).
