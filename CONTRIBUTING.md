# Contributing

Thanks for helping improve meshtasticd-proxmox. See [AGENTS.md](AGENTS.md) for why the scripts are shaped the way they are.

> [!IMPORTANT]
> Before making any contributions, you must sign our Contributor License Agreement (CLA).
> You can do this by visiting <https://cla-assistant.io/meshtastic/meshtasticd-proxmox>. Be sure to
> use the GitHub account you will use to submit your contributions when signing.

## Gates (run before every PR)

```sh
shellcheck ./*.sh
```

CI runs ShellCheck and checks that the scripts and everything under `files/` carry the SPDX header.

Those are the only checks that run without a Proxmox host. A change to a script also needs a run on a real host:

1. `./build-template.sh --id <spare-id>` builds without errors.
2. Two `--full` clones each bind `224.0.0.69:4403` on first boot (`pct exec <id> -- ss -lnu`; `239.0.0.69` on 2.8), and after `--set lora.region` they see each other in `meshtastic --host <ip> --nodes`.
3. For `add-radio.sh`, a clone with a CH341 board is heard on air by another node on the same region and preset.
4. For `update.sh`, a node with a newer version available (for example a clone pointed at the `alpha` channel) is upgraded, restarted and keeps its config, and a node that is already current is left running.

Say in the PR which of these you ran, on which Proxmox VE and meshtasticd versions, and with which board. If you could not test on a host or on air, say so.

## Conventions

- **Commits:** [Conventional Commits](https://www.conventionalcommits.org/), signed off with DCO (`git commit -s`).
- **Shell:** bash with `set -euo pipefail`, ShellCheck clean. Keep the scripts small; no option without a real use.
- **Comments:** only for invariants that are not obvious from the code, in one or two lines.
- **License:** GPL-3.0-only. The scripts and everything under `files/` carry the SPDX header (CI enforces it):
  `SPDX-FileCopyrightText: Meshtastic contributors` and `SPDX-License-Identifier: GPL-3.0-only`.
