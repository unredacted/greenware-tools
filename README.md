# GreenWare Tools

Tools for provisioning and managing [GreenWare](https://unredacted.org) — green and power-efficient hardware based on Compute Blades and Raspberry Pi.

## What's Inside

### [Provisioning](provisioning/)

Mass-provisioning tools for flashing and configuring Raspberry Pi units with:

- **Raspberry Pi OS Lite** (headless, Trixie-based with cloud-init)
- **Tailscale** connected to a Headscale server
- **Sequential hostnames** (e.g., `host1` → `host100`)
- **Zero GUI interaction** — fully automated

Two approaches are provided:

| Approach | Best For | macOS Native | Parallelizable |
|----------|----------|:------------:|:--------------:|
| [USB Provisioner](provisioning/usb-provisioner/) | Assembly-line workflow | ✅ No Docker needed | Yes (multiple USB sticks) |
| [Batch Flash](provisioning/batch-flash/) | Simpler setup | ✅ | Yes (multiple card readers) |

## Quick Start

```bash
# 1. Clone the repo
git clone https://github.com/unredacted/greenware-tools.git
cd greenware-tools

# 2. Copy and fill in your config
cp provisioning/config.env.example provisioning/config.env
# Edit provisioning/config.env with your Headscale auth key, SSH key, etc.

# 3. Download Raspberry Pi OS Lite (Trixie, 64-bit)
# From: https://downloads.raspberrypi.com/raspios_lite_arm64/images/
# Use the .img.xz file directly — no need to decompress!

# 4. Choose your approach:
#    Option A — USB Provisioner (see provisioning/usb-provisioner/README.md)
#    Option B — Batch Flash on macOS (see provisioning/batch-flash/README.md)
```

See [provisioning/README.md](provisioning/README.md) for the full guide.

## Hardware

Tested on:
- **Raspberry Pi 5** with PoE HAT
- **Compute Module 5** on carrier boards

Should work on any Raspberry Pi that supports USB boot and cloud-init.

- **Power:** PoE (Power over Ethernet) or USB-C
- **Storage:** microSD card (≥16 GB)
- **Network:** Tailscale mesh via Headscale

## License

GPLv3
