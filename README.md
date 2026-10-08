# meshtasticd-proxmox

[![CI](https://github.com/meshtastic/meshtasticd-proxmox/actions/workflows/ci.yml/badge.svg)](https://github.com/meshtastic/meshtasticd-proxmox/actions/workflows/ci.yml)
[![License: GPL-3.0](https://img.shields.io/badge/License-GPLv3-blue.svg)](LICENSE)
[![CLA assistant](https://cla-assistant.io/readme/badge/meshtastic/meshtasticd-proxmox)](https://cla-assistant.io/meshtastic/meshtasticd-proxmox)

A Proxmox VE container template that runs [meshtasticd](https://meshtastic.org/docs/software/linux/installation/) with no radio. Clone it, and the clones form a mesh with each other over UDP multicast on your LAN. Useful for testing apps, the CLI and integrations against real firmware without hardware. `add-radio.sh` puts a clone on air with a USB LoRa board.

## Build

On the Proxmox host, as root:

```sh
git clone https://github.com/meshtastic/meshtasticd-proxmox.git
cd meshtasticd-proxmox
./build-template.sh
```

This downloads the Debian 13 container image if needed, installs `meshtasticd` from the official [Meshtastic package repo](https://download.opensuse.org/repositories/network:/Meshtastic:/), configures it, wipes per-node identity and converts the container to a template. It takes a couple of minutes. The host and the container both need internet access.

| Option | Default |
| --- | --- |
| `--id <ctid>` | next free ID |
| `--storage <name>` | `local-lvm` |
| `--template-storage <name>` | `local` |
| `--bridge <name>` | `vmbr0` |
| `--channel <beta\|alpha\|daily>` | `beta` |
| `--hostname <name>` | `meshtasticd` |

On a ZFS install pass `--storage local-zfs`. The container is unprivileged, 1 core, 512 MB RAM, 4 GB disk, DHCP on the bridge. If the build fails, the half-built container is left in place for inspection and the script prints the command to remove it.

## Add a node

```sh
pct clone <template-id> <new-id> --full --hostname mesh-node1
pct start <new-id>
meshtastic --host <node-ip> --set lora.region US
```

The node starts with no region set and sends nothing until it has one. Use your own region code. `meshtastic` is the [Python CLI](https://meshtastic.org/docs/software/python/cli/) (`pipx install meshtastic`), run from any machine on the LAN.

Each clone gets a new MAC from Proxmox, and the node ID derives from it, so every clone is a distinct node with its own keys. Open the Meshtastic web client at `https://<node-ip>:9443` (meshtasticd generates a self-signed certificate on first start), or connect an app or the CLI to the node's IP on TCP port 4403. The template sets no root password; `pct enter <new-id>` gives a shell.

## Put a node on air

With a CH341 USB LoRa board (Meshtoad, MeshStick, uMesh, RAK19714) plugged into the Proxmox host, turn a clone into a radio node:

```sh
pct clone <template-id> <new-id> --full --hostname mesh-radio
./add-radio.sh <new-id> --board lora-usb-meshtoad-e22.yaml --serial <usb-serial>
meshtastic --host <node-ip> --set lora.region US --set lora.modem_preset LONG_FAST
```

`--board` is a file name from `/etc/meshtasticd/available.d` in the container; the default is `lora-usb-meshstick-1262.yaml`. `lsusb -d 1a86:5512 -v | grep iSerial` on the host prints each board's serial. The USB descriptor does not carry the board name; meshtasticd logs it as `CH341 Product` once it has opened the board, so if unsure, run with the default and check `pct exec <new-id> -- journalctl -u meshtasticd`. `--serial` is only needed when several boards are plugged in. Set the region and modem preset of the mesh you want to join; `LONG_FAST` is the default preset. Run the script again to change the board or serial.

The script adds a host udev rule that lets the container open CH341 boards (the same rule meshtasticd ships), passes `/dev/bus/usb` through so the board survives a replug, and replaces `sim.yaml` with the board config. UDP stays off on a radio node, so simulated nodes are never bridged on air.

Boards on native SPI (`/dev/spidev*`, such as Raspberry Pi HATs) are not covered: x86 Proxmox hosts have no SPI bus.

## Update

Nothing updates on its own. Each node keeps the Meshtastic package repo it was built from, and `update.sh` upgrades meshtasticd in place and restarts the nodes whose version changed:

```sh
./update.sh          # every running container tagged meshtasticd
./update.sh 105 107  # just these
```

The template is tagged `meshtasticd` and clones inherit the tag. The template keeps the version it was built with, so a new clone starts on that version until you run `update.sh` on it. To refresh the template itself, `pct destroy <template-id>` and run `./build-template.sh --id <template-id>` again; `--full` clones do not depend on it.

## How it works

- `files/sim.yaml` selects the simulated radio, enables UDP broadcast, turns on the web server and takes the node ID from `eth0`. Nodes on the same LAN find each other on multicast port 4403.
- `files/meshtasticd-wait-online.conf` holds `meshtasticd` for up to 30 s until `eth0` has an address. meshtasticd joins its multicast group once at startup, and in a container the network is reported online before the DHCP lease, so without this a node never hears the others.
- `files/ssh-regen-hostkeys.conf` gives each clone its own SSH host keys.

## Notes

- Keep every node on the same release line, and update them together. meshtasticd 2.7.x uses multicast group `224.0.0.69` and 2.8 uses `239.0.0.69`, so nodes on different lines do not hear each other.
- Do not run `meshtasticd --sim`. It skips `/etc/meshtasticd` and disables PKI encryption on packets the node sends.
- Tested on Proxmox VE 9.2 with meshtasticd 2.7.26 beta; the radio path with a Meshtoad on US `LONG_TURBO` against a RAK4631, in both directions.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Report security issues privately as described in [SECURITY.md](SECURITY.md).

## License

GPL-3.0-only, matching the Meshtastic project. See [LICENSE](LICENSE).
