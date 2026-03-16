#!/bin/bash
# =============================================================================
# GreenWare Raspberry Pi Auto-Provisioner
# =============================================================================
# This script runs on the USB provisioning stick when a Pi boots from USB.
# It flashes the target Raspberry Pi OS image onto the microSD card, injects
# cloud-init configuration (hostname, Tailscale, SSH), and increments the
# hostname counter for the next unit.
#
# Part of: https://github.com/unredacted/greenware-tools
# =============================================================================
set -euo pipefail

PROVISIONER_DIR="/opt/provisioner"
COUNTER_FILE="${PROVISIONER_DIR}/next-number.txt"
CONFIG_FILE="${PROVISIONER_DIR}/config.env"
TEMPLATE_DIR="${PROVISIONER_DIR}/cloud-init"
LOG_FILE="${PROVISIONER_DIR}/provision.log"

# --- Logging -----------------------------------------------------------------

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"; }

log_error() {
    log "ERROR: $*"
    # Blink the activity LED in a distinct error pattern (long-short-long)
    for _ in $(seq 1 5); do
        echo 1 > /sys/class/leds/ACT/brightness 2>/dev/null || true
        sleep 0.8
        echo 0 > /sys/class/leds/ACT/brightness 2>/dev/null || true
        sleep 0.2
        echo 1 > /sys/class/leds/ACT/brightness 2>/dev/null || true
        sleep 0.2
        echo 0 > /sys/class/leds/ACT/brightness 2>/dev/null || true
        sleep 0.2
        echo 1 > /sys/class/leds/ACT/brightness 2>/dev/null || true
        sleep 0.8
        echo 0 > /sys/class/leds/ACT/brightness 2>/dev/null || true
        sleep 0.5
    done
}

# --- Sanity Checks -----------------------------------------------------------

if [ ! -f "$CONFIG_FILE" ]; then
    log_error "Config file not found: $CONFIG_FILE"
    exit 1
fi

# shellcheck source=/dev/null
source "$CONFIG_FILE"

# Validate required config variables
for var in TAILSCALE_AUTH_KEY HEADSCALE_URL HOSTNAME_PREFIX HOSTNAME_SUFFIX SSH_PUBLIC_KEY ADMIN_USER; do
    if [ -z "${!var:-}" ]; then
        log_error "Required config variable $var is not set in $CONFIG_FILE"
        exit 1
    fi
done

if [ ! -f "$COUNTER_FILE" ]; then
    log_error "Counter file not found: $COUNTER_FILE"
    exit 1
fi

if [ ! -f "${TEMPLATE_DIR}/user-data.template" ]; then
    log_error "Cloud-init user-data template not found: ${TEMPLATE_DIR}/user-data.template"
    exit 1
fi

# --- Detect microSD Card -----------------------------------------------------

# On Raspberry Pi, the internal microSD slot is always /dev/mmcblk0.
# Note: /dev/mmcblk0 exists even when the slot is empty (the controller is
# always enumerated), so we must check that the device is actually writable.
SDCARD="/dev/mmcblk0"

if [ ! -b "$SDCARD" ]; then
    log_error "No microSD card detected at $SDCARD"
    log "Insert a microSD card and try again."
    exit 1
fi

# Verify the SD card is actually present and writable (not just an empty slot)
if ! dd if="$SDCARD" of=/dev/null bs=512 count=1 2>/dev/null; then
    log_error "microSD card at $SDCARD is not readable — slot may be empty"
    log "Insert a microSD card and try again."
    exit 1
fi

# --- Mount Data Partition (GWDATA) -------------------------------------------

# The compressed OS image lives on partition 3 (FAT32, label "GWDATA"),
# created by prepare-usb.sh. Find and mount it.
DATA_MOUNT="/mnt/gwdata"
TARGET_IMAGE="${DATA_MOUNT}/target-image.img.xz"

mkdir -p "$DATA_MOUNT"

# Find the GWDATA partition by label
DATA_PART=$(blkid -l -t LABEL=GWDATA -o device 2>/dev/null || true)

if [ -z "$DATA_PART" ] || [ ! -b "$DATA_PART" ]; then
    # Fallback: try partition 3 of the USB device we booted from
    ROOT_SOURCE=$(findmnt -n -o SOURCE /)
    USB_DEV_NAME=$(lsblk -no PKNAME "$ROOT_SOURCE" 2>/dev/null || true)
    if [ -n "$USB_DEV_NAME" ]; then
        DATA_PART="/dev/${USB_DEV_NAME}3"
        if [ ! -b "$DATA_PART" ]; then
            DATA_PART="/dev/${USB_DEV_NAME}p3"
        fi
    fi
fi

if [ -z "$DATA_PART" ] || [ ! -b "$DATA_PART" ]; then
    log_error "Cannot find data partition (GWDATA). Was the USB prepared with prepare-usb.sh?"
    exit 1
fi

mount -t vfat "$DATA_PART" "$DATA_MOUNT"
log "Data partition mounted: ${DATA_PART} → ${DATA_MOUNT}"

if [ ! -f "$TARGET_IMAGE" ]; then
    log_error "Target OS image not found: $TARGET_IMAGE"
    umount "$DATA_MOUNT" 2>/dev/null || true
    exit 1
fi

# --- Read and Prepare Counter ------------------------------------------------

CURRENT_NUM=$(tr -d '[:space:]' < "$COUNTER_FILE")
if ! [[ "$CURRENT_NUM" =~ ^[0-9]+$ ]]; then
    log_error "Counter file contains invalid value: '${CURRENT_NUM}'"
    log "Expected a positive integer in $COUNTER_FILE"
    exit 1
fi
NEXT_NUM=$((CURRENT_NUM + 1))
PI_HOSTNAME="${HOSTNAME_PREFIX}${CURRENT_NUM}${HOSTNAME_SUFFIX}"

log "============================================"
log "Provisioning: ${PI_HOSTNAME}"
log "  Counter:    ${CURRENT_NUM}"
log "  Next:       ${NEXT_NUM}"
log "  SD Card:    ${SDCARD}"
log "  Image:      ${TARGET_IMAGE}"
log "============================================"

# --- Flash the OS Image to microSD -------------------------------------------

log "Flashing OS image to ${SDCARD} (decompressing on the fly)..."
xz -dc "$TARGET_IMAGE" | dd of="$SDCARD" bs=4M conv=fsync 2>&1 | tee -a "$LOG_FILE"
sync
log "Flash complete."

# Unmount data partition (no longer needed)
umount "$DATA_MOUNT" 2>/dev/null || true

# Note: Root partition expansion is handled automatically by cloud-init's
# growpart module on first boot. No manual parted/resize2fs needed here.

# --- Inject Cloud-init Configuration ----------------------------------------

log "Injecting cloud-init configuration..."
mkdir -p /mnt/sd-boot
mount "${SDCARD}p1" /mnt/sd-boot

# Determine password settings
if [ -n "${ADMIN_PASSWORD:-}" ]; then
    LOCK_PASSWD="false"
else
    LOCK_PASSWD="true"
    ADMIN_PASSWORD=""
fi

# Generate user-data from template
sed \
    -e "s|__HOSTNAME__|${PI_HOSTNAME}|g" \
    -e "s|__ADMIN_USER__|${ADMIN_USER}|g" \
    -e "s|__ADMIN_PASSWORD__|${ADMIN_PASSWORD}|g" \
    -e "s|__LOCK_PASSWD__|${LOCK_PASSWD}|g" \
    -e "s|__SSH_PUBLIC_KEY__|${SSH_PUBLIC_KEY}|g" \
    -e "s|__HEADSCALE_URL__|${HEADSCALE_URL}|g" \
    -e "s|__TAILSCALE_AUTH_KEY__|${TAILSCALE_AUTH_KEY}|g" \
    "${TEMPLATE_DIR}/user-data.template" > /mnt/sd-boot/user-data

# Generate meta-data from template
sed \
    -e "s|__HOSTNAME__|${PI_HOSTNAME}|g" \
    "${TEMPLATE_DIR}/meta-data.template" > /mnt/sd-boot/meta-data

# Copy network-config (no substitution needed)
cp "${TEMPLATE_DIR}/network-config.template" /mnt/sd-boot/network-config

sync
umount /mnt/sd-boot
log "Cloud-init configuration injected."

# --- Update Counter (Atomically) ---------------------------------------------

# Write to temp file then rename — rename is atomic on most filesystems,
# protecting against power-loss corruption of the counter file
COUNTER_TMP="${COUNTER_FILE}.tmp"
echo "$NEXT_NUM" > "$COUNTER_TMP"
mv "$COUNTER_TMP" "$COUNTER_FILE"
sync
log "Counter updated: next unit will be #${NEXT_NUM}"

# --- Success Signal ----------------------------------------------------------

log "============================================"
log "SUCCESS: ${PI_HOSTNAME} is ready!"
log "  Pi will power off in 30 seconds."
log "  After power-off:"
log "    1. Remove the USB stick"
log "    2. Reconnect Ethernet — Pi boots from microSD"
log "    3. Cloud-init will auto-configure the Pi"
log "============================================"

# Blink the activity LED rapidly for 10 seconds to signal completion
for _ in $(seq 1 20); do
    echo 1 > /sys/class/leds/ACT/brightness 2>/dev/null || true
    sleep 0.25
    echo 0 > /sys/class/leds/ACT/brightness 2>/dev/null || true
    sleep 0.25
done

# Power off so the user can safely remove USB + SD
log "Powering off..."
sleep 5
poweroff
