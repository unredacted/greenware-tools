# USB Provisioner

A bootable USB stick that auto-provisions Raspberry Pi units. Plug it in, connect power, and walk away — the Pi flashes its own microSD and configures itself.

Tested on Raspberry Pi 5 and Compute Module 5. No Docker required.

## How It Works

```
Insert blank microSD → Plug USB → Connect power
    → Pi boots from USB (SD is blank, falls through)
    → provision.sh flashes OS to microSD
    → Cloud-init config injected (hostname, Tailscale, SSH)
    → LED blinks rapidly = done → Pi powers off
    → Remove USB, reconnect power → Pi boots from microSD
    → Cloud-init runs: NTP sync, hostname set, Tailscale joined
    → Pi appears on your tailnet ✅
```

## USB Layout

After `prepare-usb.sh`, the USB stick has three partitions:

| # | Type | Label | Contents |
|---|------|-------|----------|
| 1 | FAT32 | bootfs | Pi boot files + provisioner scripts + cloud-init |
| 2 | ext4 | rootfs | Raspberry Pi OS (expanded by growpart on first boot) |
| 3 | FAT32 | GWDATA | Compressed OS image (`target-image.img.xz`) |

## Setup

### Prerequisites

- Raspberry Pi OS Lite `.img.xz` file (as-downloaded — no decompression needed)
- A filled-in `config.env`
- macOS or Linux (no Docker required)

### Prepare the USB Stick

```bash
# 1. Fill in your config
cp provisioning/config.env.example provisioning/config.env
# Edit provisioning/config.env — set USB_DISK, auth key, SSH key, etc.

# 2. Identify your USB stick
diskutil list   # macOS
lsblk           # Linux

# 3. Run the script
./provisioning/usb-provisioner/prepare-usb.sh
```

### First Boot (One-Time)

The USB needs to boot **once** on any Pi to finish setup:

1. Plug the USB into any Pi (no microSD needed)
2. Connect power and wait ~2 minutes
3. The Pi moves provisioner files from boot to rootfs, installs the service, and reboots
4. After reboot, the green LED blinks rapidly (looking for a microSD)
5. Power off and remove the USB — it's now ready

### Assembly-Line Provisioning

Repeat for each Pi:

1. Insert a blank microSD into the Pi
2. Plug in the USB stick
3. Connect power (PoE or USB-C)
4. Wait for rapid LED blink → Pi powers off automatically
5. Remove USB stick
6. Reconnect power → Pi boots from SD and configures itself
7. Pi appears on your tailnet with the next hostname

Each provisioning increments the hostname counter automatically, so every Pi gets a unique hostname.

## File Structure

```
usb-provisioner/
├── prepare-usb.sh          # Run on your Mac/Linux to prepare the USB
├── firstboot-setup.sh      # Runs once on Pi to move files to rootfs
├── provision.sh            # Core provisioning logic (runs on each Pi)
├── auto-provision.service  # Systemd service — auto-starts provision.sh
└── README.md
```

## Troubleshooting

### USB stick not booting
- Ensure boot order has USB before SD: `sudo rpi-eeprom-config --edit` → set `BOOT_ORDER=0xf416`
- Try a different USB port
- If using PoE, `usb_max_current_enable=1` is set in config.txt automatically

### Provision fails
- Check logs: `cat /opt/provisioner/provision.log`
- Verify the SD card is inserted and empty
- SSH in via Tailscale if the USB's first boot completed

### Cloud-init issues on provisioned SD
- Read the log: mount the SD on your Mac and check `/Volumes/bootfs/cloud-init-output.log`
- Common issue: wrong system clock → NTP sync step handles this automatically

### Console access
- Set `ADMIN_PASSWORD` in config.env if you need local keyboard+monitor login
- SSH uses key-only auth regardless of password setting

### LED patterns
- **Rapid blink (short)**: Success — provisioning complete
- **Slow blink (long-short-long)**: Error — check the log
