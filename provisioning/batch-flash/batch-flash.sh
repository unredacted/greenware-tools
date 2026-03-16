#!/bin/bash
# =============================================================================
# GreenWare Batch Flash — macOS SD Card Provisioner
# =============================================================================
# Flash and configure microSD cards one at a time from macOS. This approach
# writes cloud-init files directly to the FAT32 boot partition, which macOS
# handles natively — no Docker or ext4 tools needed.
#
# Prerequisites:
#   - Decompressed Raspberry Pi OS Lite .img file
#   - A filled-in config.env (copy from config.env.example)
#   - A USB SD card reader connected to your Mac
#
# Usage:
#   ./batch-flash.sh [path-to-config.env]
#
# Part of: https://github.com/unredacted/greenware-tools
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# --- Load Config -------------------------------------------------------------

CONFIG_FILE="${1:-${REPO_ROOT}/provisioning/config.env}"

if [ ! -f "$CONFIG_FILE" ]; then
    echo "ERROR: Config file not found: $CONFIG_FILE"
    echo ""
    echo "Create one from the template:"
    echo "  cp provisioning/config.env.example provisioning/config.env"
    echo "  # Edit provisioning/config.env with your values"
    echo ""
    echo "Or specify the path:"
    echo "  $0 /path/to/config.env"
    exit 1
fi

# shellcheck source=/dev/null
source "$CONFIG_FILE"

# Validate required variables
for var in TAILSCALE_AUTH_KEY HEADSCALE_URL HOSTNAME_PREFIX HOSTNAME_SUFFIX \
           SSH_PUBLIC_KEY ADMIN_USER OS_IMAGE SD_DISK HOSTNAME_START HOSTNAME_END; do
    if [ -z "${!var:-}" ]; then
        echo "ERROR: Required variable $var is not set in $CONFIG_FILE"
        exit 1
    fi
done

# Locate the OS image
if [ -f "$OS_IMAGE" ]; then
    IMAGE_PATH="$OS_IMAGE"
elif [ -f "${REPO_ROOT}/${OS_IMAGE}" ]; then
    IMAGE_PATH="${REPO_ROOT}/${OS_IMAGE}"
else
    echo "ERROR: OS image not found: $OS_IMAGE"
    echo "       Download from: https://downloads.raspberrypi.com/raspios_lite_arm64/images/"
    echo "       Decompress:    xz -d <filename>.img.xz"
    exit 1
fi

# Derive the raw disk path for faster dd on macOS
# shellcheck disable=SC2153  # SD_DISK is sourced from config.env
SD_RDISK="${SD_DISK/disk/rdisk}"

# Template paths
USER_DATA_TEMPLATE="${REPO_ROOT}/provisioning/cloud-init/user-data.template"
META_DATA_TEMPLATE="${REPO_ROOT}/provisioning/cloud-init/meta-data.template"
NETWORK_CONFIG_TEMPLATE="${REPO_ROOT}/provisioning/cloud-init/network-config.template"

for template in "$USER_DATA_TEMPLATE" "$META_DATA_TEMPLATE" "$NETWORK_CONFIG_TEMPLATE"; do
    if [ ! -f "$template" ]; then
        echo "ERROR: Template not found: $template"
        exit 1
    fi
done

# --- Drive Safety Validation -------------------------------------------------
# Multiple layers of protection to prevent wiping the wrong drive.

echo ""
echo "Validating target disk ${SD_DISK}..."

# Check 1: Device must exist
if [ ! -b "$SD_DISK" ]; then
    echo "ERROR: ${SD_DISK} is not a valid block device."
    echo "       Run 'diskutil list' to find your SD card reader."
    exit 1
fi

# Check 2: Refuse the system/boot disk
DISK_NUM="${SD_DISK##*/disk}"
if [ "$DISK_NUM" = "0" ] || [ "$DISK_NUM" = "1" ]; then
    echo "FATAL: ${SD_DISK} is the macOS system disk!"
    echo "       Refusing to continue. This would destroy your OS."
    exit 1
fi

if diskutil info "$SD_DISK" 2>/dev/null | grep -qi "APFS\|Macintosh HD\|Apple_APFS"; then
    echo "FATAL: ${SD_DISK} contains APFS/macOS partitions!"
    echo "       Refusing to continue. This is likely your system disk."
    exit 1
fi

# Check 3: Refuse internal/fixed drives
DISK_INTERNAL=$(diskutil info "$SD_DISK" 2>/dev/null | grep -i "Internal:" | awk '{print $NF}' || true)
DISK_REMOVABLE=$(diskutil info "$SD_DISK" 2>/dev/null | grep -i "Removable Media:" | awk '{print $NF}' || true)
if [ "$DISK_INTERNAL" = "Yes" ] && [ "$DISK_REMOVABLE" != "Removable" ]; then
    echo "FATAL: ${SD_DISK} is an internal, non-removable disk!"
    echo "       This script only writes to external/removable drives."
    echo ""
    diskutil info "$SD_DISK" | grep -E "Device / Media Name:|Internal:|Removable Media:|Disk Size:" || true
    exit 1
fi

# Check 4: Size sanity — refuse drives outside 4GB–256GB range
DISK_SIZE_BYTES=$(diskutil info "$SD_DISK" 2>/dev/null | grep "Disk Size:" | grep -oE '[0-9]+ Bytes' | awk '{print $1}' || true)
DISK_SIZE_BYTES="${DISK_SIZE_BYTES:-0}"
if [ "$DISK_SIZE_BYTES" -gt 0 ] 2>/dev/null; then
    DISK_SIZE_GB=$(( DISK_SIZE_BYTES / 1024 / 1024 / 1024 ))
    MIN_SIZE=$((4 * 1024 * 1024 * 1024))
    MAX_SIZE=$((256 * 1024 * 1024 * 1024))

    if [ "$DISK_SIZE_BYTES" -lt "$MIN_SIZE" ]; then
        echo "FATAL: ${SD_DISK} is only ${DISK_SIZE_GB} GB — too small."
        exit 1
    fi
    if [ "$DISK_SIZE_BYTES" -gt "$MAX_SIZE" ]; then
        echo "FATAL: ${SD_DISK} is ${DISK_SIZE_GB} GB — suspiciously large for an SD card."
        echo "       Maximum allowed: 256 GB. This check protects against wiping large external drives."
        exit 1
    fi
    echo "  ✅ Disk size: ${DISK_SIZE_GB} GB (within 4–256 GB range)"
fi

echo "  ✅ Disk is external/removable"
echo "  ✅ Disk is not a system drive"

# --- Safety Confirmation -----------------------------------------------------

echo ""
echo "============================================"
echo "GreenWare Batch Flash — macOS SD Provisioner"
echo "============================================"
echo ""
echo "  Image:      ${IMAGE_PATH}"
echo "  SD Disk:    ${SD_DISK} (raw: ${SD_RDISK})"
echo "  Range:      ${HOSTNAME_PREFIX}${HOSTNAME_START}${HOSTNAME_SUFFIX}"
echo "              through"
echo "              ${HOSTNAME_PREFIX}${HOSTNAME_END}${HOSTNAME_SUFFIX}"
echo "  Total:      $(( HOSTNAME_END - HOSTNAME_START + 1 )) units"
echo ""

# Show disk details
echo "  --- Disk Details ---"
diskutil info "$SD_DISK" 2>/dev/null | grep -E "Device / Media Name:|Disk Size:|Device Location:|Removable Media:" | sed 's/^/  /' || true
echo ""

echo "⚠️  WARNING: This will PERMANENTLY ERASE ${SD_DISK} (repeatedly)!"
echo ""
echo "   To confirm, type the disk identifier exactly: ${SD_DISK}"
echo ""
read -rp "Disk identifier: " CONFIRM_DISK
if [ "$CONFIRM_DISK" != "$SD_DISK" ]; then
    echo "Aborted — input did not match ${SD_DISK}."
    exit 0
fi

# --- Flash Loop --------------------------------------------------------------

FLASHED=0
FAILED=0

for i in $(seq "$HOSTNAME_START" "$HOSTNAME_END"); do
    PI_HOSTNAME="${HOSTNAME_PREFIX}${i}${HOSTNAME_SUFFIX}"
    echo ""
    echo "╔════════════════════════════════════════════╗"
    echo "║  Provisioning: ${PI_HOSTNAME}"
    echo "║  Unit $((i - HOSTNAME_START + 1)) of $(( HOSTNAME_END - HOSTNAME_START + 1 ))"
    echo "╚════════════════════════════════════════════╝"
    echo ""
    read -rp "Insert microSD card #${i} and press Enter (or 'q' to quit)... " INPUT

    if [ "$INPUT" = "q" ] || [ "$INPUT" = "Q" ]; then
        echo "Stopping at unit ${i}. ${FLASHED} units flashed successfully."
        break
    fi

    # Unmount (not eject) the SD card
    echo "[1/4] Unmounting ${SD_DISK}..."
    diskutil unmountDisk "$SD_DISK" 2>/dev/null || true

    # Flash the image
    echo "[2/4] Flashing image (press Ctrl+T for progress)..."
    if ! sudo dd if="$IMAGE_PATH" of="$SD_RDISK" bs=4m 2>&1; then
        echo "❌ ERROR: dd failed for ${PI_HOSTNAME}. Skipping."
        FAILED=$((FAILED + 1))
        continue
    fi
    sync

    # Wait for macOS to auto-mount the boot partition
    echo "[3/4] Waiting for boot partition to mount..."
    BOOT_MOUNT=""
    for _attempt in $(seq 1 10); do
        sleep 2
        BOOT_MOUNT=$(mount | grep "${SD_DISK}s1" | awk '{print $3}' || true)
        if [ -n "$BOOT_MOUNT" ]; then
            break
        fi
        # Try manually mounting
        diskutil mount "${SD_DISK}s1" 2>/dev/null || true
    done

    if [ -z "$BOOT_MOUNT" ]; then
        echo "❌ ERROR: Could not mount boot partition for ${PI_HOSTNAME}. Skipping."
        FAILED=$((FAILED + 1))
        continue
    fi

    echo "   Boot partition: ${BOOT_MOUNT}"

    # Write cloud-init configuration
    echo "[4/4] Injecting cloud-init config..."

    # Generate user-data from template
    sed \
        -e "s|__HOSTNAME__|${PI_HOSTNAME}|g" \
        -e "s|__ADMIN_USER__|${ADMIN_USER}|g" \
        -e "s|__SSH_PUBLIC_KEY__|${SSH_PUBLIC_KEY}|g" \
        -e "s|__HEADSCALE_URL__|${HEADSCALE_URL}|g" \
        -e "s|__TAILSCALE_AUTH_KEY__|${TAILSCALE_AUTH_KEY}|g" \
        "$USER_DATA_TEMPLATE" > "${BOOT_MOUNT}/user-data"

    # Generate meta-data from template
    sed \
        -e "s|__HOSTNAME__|${PI_HOSTNAME}|g" \
        "$META_DATA_TEMPLATE" > "${BOOT_MOUNT}/meta-data"

    # Copy network-config
    cp "$NETWORK_CONFIG_TEMPLATE" "${BOOT_MOUNT}/network-config"

    # Safely eject
    sync
    diskutil eject "$SD_DISK"

    FLASHED=$((FLASHED + 1))
    echo "✅ ${PI_HOSTNAME} ready — remove card and label it"
done

# --- Summary -----------------------------------------------------------------

echo ""
echo "============================================"
echo "Batch Flash Complete"
echo "============================================"
echo "  Flashed:  ${FLASHED}"
echo "  Failed:   ${FAILED}"
echo "  Total:    $(( HOSTNAME_END - HOSTNAME_START + 1 ))"
echo ""
echo "Insert each card into its Pi, connect PoE,"
echo "and they'll auto-configure via cloud-init."
echo "============================================"
