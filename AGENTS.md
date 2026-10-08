# AGENTS.md

Working notes for meshtasticd-proxmox: two bash scripts that build a Proxmox VE container template running meshtasticd, and turn a clone of it into an on-air node. Read [CONTRIBUTING.md](CONTRIBUTING.md) for the gates; this file is about why the scripts look the way they do.

## The shape of it

| file | does |
| --- | --- |
| `build-template.sh` | creates a Debian 13 CT, installs meshtasticd from OBS, pushes `files/`, wipes identity, converts it to a template |
| `add-radio.sh` | on a clone: host udev rule, USB passthrough in the CT config, replaces `sim.yaml` with the board config plus a `node.yaml` (node ID from the MAC, UDP off) |
| `files/sim.yaml` | SimRadio, `EnableUDP`, node ID from the `eth0` MAC |
| `files/meshtasticd-wait-online.conf` | holds meshtasticd for up to 30 s until `eth0` has an IPv4 address |
| `files/ssh-regen-hostkeys.conf` | generates any missing SSH host keys before sshd starts, so each clone gets its own |

## Invariants worth knowing before you change anything

- **meshtasticd joins its UDP multicast group once, at startup.** If `eth0` has no address yet the join fails silently and the node never hears its peers. In an LXC container `network-online.target` is reached before the DHCP lease, so `After=`/`Wants=` alone do not help; the `ExecStartPre` loop waits up to 30 s for an address, then lets meshtasticd start regardless.
- **Never use `meshtasticd --sim`.** It skips `/etc/meshtasticd` and sets `force_simradio`, which disables PKI encryption on packets the node sends. `Lora: Module: sim` in YAML selects the same radio without either problem.
- **A node with region `UNSET` sends nothing**, and the YAML cannot set a region. Every new node needs `--set lora.region` over the API.
- **The template must carry no identity.** `build-template.sh` removes `/var/lib/meshtasticd/.portduino` (node keys and prefs), the SSH host keys, `machine-id` and DHCP leases. A clone with any of these shares it with every sibling.
- **The node ID comes from the MAC** (`MACAddressSource: eth0`), and Proxmox gives each clone a new MAC.
- **A template is not changed in place.** Change the scripts and rebuild.
- **`/etc/pve/lxc/<id>.conf` has sections.** Lines after a `[snapshot]` or `[pve:pending]` header belong to that section, so `add-radio.sh` inserts above the first header and writes through a temp file and rename, as Proxmox does.
- **`pct push` creates files as container root.** Anything meshtasticd must own needs a `chown` inside the container.
- **Radio nodes keep UDP off**, so simulated nodes are never relayed on air.

## Testing

There are no unit tests: the scripts drive `pct`, `pveam` and apt on a real host. ShellCheck catches shell mistakes; everything else needs the host checklist in CONTRIBUTING.md. When a change is untested on a host or on air, say so.

## Gotchas

- Released 2.7.x binds multicast `224.0.0.69`; firmware `develop` uses `239.0.0.69`. Nodes on different lines do not hear each other.
- The package enables and starts `meshtasticd.service` at install with only its default `config.yaml`, and the unit restarts on failure every 3 s; `build-template.sh` stops it right after install and enables it again once configured.
- `lsusb -v` shows a CH341 board's serial but not its name. meshtasticd logs the name as `CH341 Product` once it opens the board.
