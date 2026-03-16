# Provisioning Guide

Mass-provision Raspberry Pi units with Raspberry Pi OS, Tailscale, and sequential hostnames. Each provisioned Pi will:

1. Boot from microSD with Raspberry Pi OS Lite (Trixie)
2. Auto-configure via cloud-init (hostname, user account, SSH keys)
3. Install Tailscale and join your Headscale tailnet
4. Be accessible via Tailscale SSH — no password auth

Tested on Raspberry Pi 5 and Compute Module 5.

## Prerequisites

### Hardware
- Raspberry Pi units with PoE HATs or USB-C power
- microSD cards (≥16 GB), one per Pi
- PoE switch with sufficient power budget (~12W per Pi under load)
- Mac or Linux workstation for preparation

### Software (macOS)
```bash
brew install coreutils
# No Docker required!
```

### Accounts & Keys
1. **Headscale pre-auth key** (reusable):
   ```bash
   headscale preauthkeys create --user <YOUR_USER> --reusable --expiration 90d
   ```
2. **SSH public key** (ed25519 recommended)
3. **Raspberry Pi OS Lite image** (Trixie, 64-bit):
   ```bash
   # Download from https://downloads.raspberrypi.com/raspios_lite_arm64/images/
   # Use the .img.xz file directly — no decompression needed!
   ```

## Configuration

All settings are in a single `config.env` file:

```bash
cp config.env.example config.env
# Edit config.env with your values
```

> **⚠️ Never commit `config.env` to git** — it contains your Tailscale auth key.

See [config.env.example](config.env.example) for all available settings.

## Approaches

### Option A: USB Provisioner (Recommended for 50+ units)

A USB stick that auto-provisions Pis when plugged in. See [usb-provisioner/README.md](usb-provisioner/README.md).

**Workflow:** Insert microSD → Plug USB → Connect PoE → Wait for LED blink → Done.

### Option B: Batch Flash on macOS (Simpler setup)

Flash microSD cards one at a time from your Mac. See [batch-flash/README.md](batch-flash/README.md).

**Workflow:** Insert SD card → Script flashes & configures → Eject → Label → Repeat.

## Verification

After provisioning, verify your fleet:

```bash
./verify/verify-fleet.sh
```

This checks each Pi's connectivity via `tailscale ping`. See the script output for troubleshooting guidance on offline units.

## Cloud-init Templates

The `cloud-init/` directory contains the templates injected onto each microSD card:

| File | Purpose |
|------|---------|
| `user-data.template` | User account, SSH keys, Tailscale setup, packages |
| `meta-data.template` | Instance ID and hostname |
| `network-config.template` | Ethernet DHCP configuration |

Placeholders (e.g., `__HOSTNAME__`, `__TAILSCALE_AUTH_KEY__`) are substituted at provisioning time from your `config.env`.

## Security Notes

- **Auth key redaction:** The Tailscale auth key is automatically removed from cloud-init artifacts on first boot
- **SSH key-only:** Password auth is disabled over SSH; only your configured SSH key grants access
- **Console password:** Optional — set `ADMIN_PASSWORD` in config.env for local keyboard+monitor login
- **Tailscale SSH:** Standard SSH is replaced by Tailscale SSH (`--accept-risk=lose-ssh`); manage access through Headscale ACLs
- **Post-provisioning:** Revoke the reusable pre-auth key:
  ```bash
  headscale preauthkeys expire --id <KEY_ID>
  ```

## Boot Order

Default EEPROM boot order is `0xf41` (SD → USB → loop). For the USB provisioner:
- **Blank microSD:** Pi can't boot from SD, falls through to USB ✅
- **Previously-used microSD:** Pi boots from SD instead of USB ❌ — wipe or use a new card

If you need to change boot order: `sudo rpi-eeprom-config --edit` on a running Pi.

## PoE Power Budget

| State | Power Draw |
|----------|-----------|
| Idle | ~5W |
| Flashing SD (provisioning) | ~8–12W |
| PoE HAT max | 25.5W |

A 48-port PoE switch with 740W budget can handle ~30–40 Pis simultaneously.

## Batching with Multiple USB Sticks

For parallel provisioning, create multiple USB sticks with different starting counters by changing `HOSTNAME_START` in `config.env` before each `prepare-usb.sh` run.
