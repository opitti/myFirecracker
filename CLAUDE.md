# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

A personal workspace for orchestrating multiple [Firecracker](https://firecracker-microvm.github.io/) microVMs on a Linux host. It does **not** build Firecracker from source — it downloads pre-built binaries and kernels, then scripts the network + storage setup to run several isolated VMs in parallel.

## Prepare artifacts

```bash
bash script/get-kernel.sh        # download kernel, rootfs, SSH keys; apply rootfs overlay
bash get-firecracker.sh          # download pre-built firecracker binary
```

## Run VMs

Each VM needs two terminals (or background processes):

```bash
# Terminal A — start daemon
./multi-vm-explore/run-firecracker.sh vm1

# Terminal B — configure and boot via API
./multi-vm-explore/call-firecracker.sh vm1
```

Repeat with `vm2`, `vm3`, etc. for additional VMs.

Legacy single-VM equivalents: `run-firecracker.sh` / `call-firecracker.sh` at repo root.

## Architecture

### Three-layer design

1. **Shared artifact preparation** (`script/get-kernel.sh`)
   - Downloads kernel (`vmlinux-6.1.x`) and Ubuntu rootfs (`ubuntu-24.04.ext4`)
   - Injects the rootfs overlay (network + mount setup) via `multi-vm-explore/apply-rootfs-overlay.sh`

2. **Per-VM host setup** (`multi-vm-explore/run-firecracker.sh <vm-id>`)
   - Allocates a unique IP in `172.16.0.2–14/28`, derives a MAC from it
   - Creates per-VM state dir (`state/vms/<vm-id>/`) and an app-data disk (`app-data.ext4`)
   - Launches the Firecracker daemon on a per-VM Unix socket (`/tmp/firecracker-<vm-id>.socket`)
   - Uses a lockfile to serialize concurrent launches

3. **VM boot via API** (`multi-vm-explore/call-firecracker.sh <vm-id>`)
   - Creates bridge `fcbr0` (172.16.0.1/28) and a TAP interface per VM (`fctap2`, `fctap3`, …)
   - Configures iptables MASQUERADE for guest internet access
   - Calls the Firecracker HTTP API to attach kernel, rootfs, app disk, and network, then boots

### Guest-side setup (rootfs overlay)

`multi-vm-explore/rootfs-overlay/usr/local/bin/fcnet-setup.sh` runs as a systemd service on every guest boot:
- Derives the guest IP from the MAC address (bytes → `172.16.0.XX/28`)
- Adds a default route via `172.16.0.1`
- Mounts `/dev/vdb` at `/app` if present

### Network topology

```
Host (172.16.0.1)
└── fcbr0 (bridge, /28)
    ├── fctap2 ──── VM vm1  172.16.0.2
    ├── fctap3 ──── VM vm2  172.16.0.3
    └── ...
[iptables MASQUERADE] → host eth0 → internet
```

### Storage

- **Shared rootfs** — `ubuntu-24.04.ext4` (read-only, common OS image)
- **Per-VM app disk** — `state/vms/<vm-id>/app-data.ext4` (mounted at `/app` inside guest)

## Key files

| File | Role |
|------|------|
| `script/get-kernel.sh` | Download + assemble all artifacts |
| `multi-vm-explore/run-firecracker.sh` | Launch Firecracker daemon per VM |
| `multi-vm-explore/call-firecracker.sh` | Boot VM via Firecracker HTTP API |
| `multi-vm-explore/apply-rootfs-overlay.sh` | Inject overlay into rootfs image |
| `multi-vm-explore/rootfs-overlay/usr/local/bin/fcnet-setup.sh` | Guest network + mount init |

## Documentation

Detailed docs and session notes live alongside the scripts:

- `multi-vm-explore/doc/` — line-by-line script explanations and a reading-order index
- `firecracker-network-diagrams.md` / `firecracker-network-glossary.md` — networking reference
- `SESSION-YYYY-MM-DD-*.md` files — running log of decisions and bug fixes
