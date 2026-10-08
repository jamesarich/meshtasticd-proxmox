# meshtasticd-proxmox

[![CI](https://github.com/meshtastic/meshtasticd-proxmox/actions/workflows/ci.yml/badge.svg)](https://github.com/meshtastic/meshtasticd-proxmox/actions/workflows/ci.yml)
[![License: GPL-3.0](https://img.shields.io/badge/License-GPLv3-blue.svg)](LICENSE)
[![CLA assistant](https://cla-assistant.io/readme/badge/meshtastic/meshtasticd-proxmox)](https://cla-assistant.io/meshtastic/meshtasticd-proxmox)

These scripts build a Proxmox VE container template that runs [meshtasticd](https://meshtastic.org/docs/meshtasticd/), the Meshtastic firmware for Linux. Each clone of the template is a node with a simulated radio, and the clones form a mesh with each other over UDP multicast, which reaches every node on the same network segment. That gives clients, the CLI, and integrations real firmware to test against without hardware. A clone can also go on air with a USB LoRa board.

## Requirements

- Proxmox VE, with a root shell on the host. The host and the containers need internet access.
- The [Meshtastic Python CLI](https://meshtastic.org/docs/software/python/cli/) on any machine on the LAN, to set each node's region (`pipx install meshtastic`).
- For an on-air node, a CH341 USB LoRa board plugged into the host. See [Put a node on air](#put-a-node-on-air).

## Build the template

On the Proxmox host, as root:

```shell
git clone https://github.com/meshtastic/meshtasticd-proxmox.git
cd meshtasticd-proxmox
./build-template.sh
```

The script downloads the Debian 13 container image if needed, installs meshtasticd from the official [Meshtastic package repository](https://download.opensuse.org/repositories/network:/Meshtastic:/), configures it, wipes per-node identity, and converts the container to a template. It takes a few minutes and ends with `CT <ID> is a template with meshtasticd <VERSION>`.

| Option | Default |
| --- | --- |
| `--id <CTID>` | next free container ID |
| `--storage <NAME>` | `local-lvm` |
| `--template-storage <NAME>` | `local` |
| `--bridge <NAME>` | `vmbr0` |
| `--channel <beta\|alpha\|daily>` | `beta` |
| `--hostname <NAME>` | `meshtasticd` |

On a ZFS install, pass `--storage local-zfs`. The container is unprivileged, with one core, 512 MB of RAM, a 4 GB disk, and DHCP on the bridge. If the build fails, the half-built container stays in place for inspection and the script prints the command to remove it.

## Add a node

Replace `<TEMPLATE_ID>` with the template's container ID, `<NEW_ID>` with a free container ID, and `<NODE_IP>` with the address the new container gets from DHCP (`pct exec <NEW_ID> -- ip -4 addr show eth0`).

1. Clone the template:

   ```shell
   pct clone <TEMPLATE_ID> <NEW_ID> --full --hostname mesh-node1
   ```

2. Start the node:

   ```shell
   pct start <NEW_ID>
   ```

3. Set the node's region to yours. The node sends nothing until its region is set.

   ```shell
   meshtastic --host <NODE_IP> --set lora.region US
   ```

4. Confirm it joined the mesh. After a minute, the other nodes appear in its node list:

   ```shell
   meshtastic --host <NODE_IP> --nodes
   ```

Each clone gets a new MAC address from Proxmox, and the node ID derives from it, so every clone is a distinct node with its own keys. The Meshtastic web client is at `https://<NODE_IP>:9443`; meshtasticd generates a self-signed certificate on first start. Clients and the CLI connect to TCP port 4403. The template sets no root password, so `pct enter <NEW_ID>` gives a shell.

## Put a node on air

With a CH341 USB LoRa board (Meshtoad, MeshStick, uMesh, or RAK19714) plugged into the host, turn a clone into an on-air node. Replace `<BOARD_FILE>` with the board's file name from `/etc/meshtasticd/available.d` in the container, and `<USB_SERIAL>` with the board's USB serial number.

1. Clone the template:

   ```shell
   pct clone <TEMPLATE_ID> <NEW_ID> --full --hostname mesh-radio
   ```

2. Attach the board:

   ```shell
   ./add-radio.sh <NEW_ID> --board <BOARD_FILE> --serial <USB_SERIAL>
   ```

3. Set the region and modem preset of the mesh you want to join:

   ```shell
   meshtastic --host <NODE_IP> --set lora.region US --set lora.modem_preset LONG_FAST
   ```

The default board file is `lora-usb-meshstick-1262.yaml`; a Meshtoad uses `lora-usb-meshtoad-e22.yaml`. On the host, `lsusb -d 1a86:5512 -v | grep iSerial` prints each board's serial number. The USB descriptor doesn't carry the board name, but meshtasticd logs it as `CH341 Product` once it opens the board. `--serial` is only needed when several boards are plugged in. Long Fast is the default modem preset. To change the board or serial, run the script again.

The script adds a host udev rule that lets the container open CH341 boards (the same rule meshtasticd ships), and passes `/dev/bus/usb` through so the board survives a replug. It replaces `sim.yaml` with the board's configuration and a `node.yaml` that keeps the node ID and the web client. UDP stays off on an on-air node, so simulated nodes are never relayed on air.

If the node hears no other nodes, check that the radio started:

```shell
pct exec <NEW_ID> -- journalctl -u meshtasticd -b
```

The log shows `CH341 Serial <USB_SERIAL>` and `sx1262 init success` once the board is open. If both lines are there, the likely cause is a region or modem preset that differs from the local mesh's; a node only hears nodes on the same modem preset. If they're missing, check the board file and that the board appears in `lsusb` on the host.

Boards on native SPI (Serial Peripheral Interface, `/dev/spidev*`), such as Raspberry Pi HATs, aren't covered: x86 Proxmox hosts have no SPI bus.

## Update meshtasticd

Nothing updates on its own. Each node keeps the Meshtastic package repository it was built from, and `update.sh` upgrades meshtasticd in place, then restarts the nodes whose version changed. With no arguments it updates every running container tagged `meshtasticd`:

```shell
./update.sh
```

To update specific containers, pass their IDs:

```shell
./update.sh <CTID> <CTID>
```

The template is tagged `meshtasticd` and clones inherit the tag. The template keeps the version it was built with, so a new clone starts on that version until `update.sh` runs on it. To refresh the template itself, run `pct destroy <TEMPLATE_ID>`, then `./build-template.sh --id <TEMPLATE_ID>`; `--full` clones don't depend on it.

Keep every node on the same release line and update them together. meshtasticd 2.7.x uses multicast group `224.0.0.69` and 2.8 uses `239.0.0.69`, so nodes on different lines don't hear each other.

## How it works

- `files/sim.yaml` selects the simulated radio, enables UDP broadcast, turns on the web server, and takes the node ID from `eth0`. Nodes on the same LAN find each other on multicast port 4403.
- `files/meshtasticd-wait-online.conf` holds meshtasticd for up to 30 s until `eth0` has an address. meshtasticd joins its multicast group once at startup, and in a container the network is reported online before the DHCP lease, so without this wait a node never hears the others.
- `files/ssh-regen-hostkeys.conf` gives each clone its own SSH host keys.

Do not start meshtasticd with `--sim`. That flag skips `/etc/meshtasticd` and disables PKI encryption on the packets the node sends.

## Tested versions

| Component | Versions |
| --- | --- |
| Proxmox VE | 9.2 (tested here); 8.4.21 reported working by a Meshtastic admin |
| meshtasticd | 2.7.26 beta; `update.sh` upgraded a node from 2.7.26 beta to 2.8.1 alpha |
| On-air node | Meshtoad on US Long Turbo, heard both ways by a RAK4631; tested before radio nodes kept the web client |

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Report security issues privately as described in [SECURITY.md](SECURITY.md).

## License

GPL-3.0-only, matching the Meshtastic project. See [LICENSE](LICENSE).
