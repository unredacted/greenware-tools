# Batch Flash (macOS)

Flash and configure microSD cards one at a time directly from your Mac. This approach only writes to the FAT32 boot partition, which macOS handles natively — no Docker or ext4 tools needed.

## How It Works

```
Insert SD card → Script flashes with dd → Cloud-init config written
    → Eject → Label card → Insert into Pi → Connect PoE
    → Cloud-init runs: hostname set, Tailscale joined
    → Pi appears on your tailnet ✅
```

## Usage

```bash
# 1. Fill in your config
cp provisioning/config.env.example provisioning/config.env
# Edit config.env (auth key, SSH key, disk identifier, etc.)

# 2. Download and decompress the OS image
xz -d 2025-12-04-raspios-trixie-arm64-lite.img.xz

# 3. Identify your SD card reader
diskutil list
# Update SD_DISK in config.env (e.g., /dev/disk4)

# 4. Run the batch flash script
./provisioning/batch-flash/batch-flash.sh

# 5. For each unit:
#    - Insert a microSD card and press Enter
#    - Wait for flash + config injection
#    - Remove card and label it
#    - Repeat
```

## Safety

The script will:
- Show you which disk it will write to
- Ask you to type `yes` to confirm
- Let you type `q` at any prompt to quit early

> **⚠️ Double-check `SD_DISK` in your config.env.** Writing to the wrong disk will destroy data.
>
> Verify with: `diskutil list`

## Tips

- **Label your cards!** Write the hostname number on each card as you go
- **Speed:** Use a fast USB 3.0 SD card reader for quicker `dd` writes
- Press **Ctrl+T** during `dd` to see progress
- Run from a directory containing your `.img` file, or set the `OS_IMAGE` path in `config.env`
- To quit partway through, type `q` when prompted. The script reports how many were completed

## Multiple Card Readers

To provision in parallel, run multiple instances of the script with different counter ranges. Edit `HOSTNAME_START` and `HOSTNAME_END` in separate `config.env` files:

```bash
# Terminal 1 (units 26–75, SD reader at /dev/disk4)
./batch-flash.sh config-a.env

# Terminal 2 (units 76–125, SD reader at /dev/disk5)
./batch-flash.sh config-b.env
```
