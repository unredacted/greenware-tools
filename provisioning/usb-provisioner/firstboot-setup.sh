#!/bin/bash
# =============================================================================
# GreenWare USB Provisioner — First Boot Setup
# =============================================================================
# Runs ONCE on the USB stick's first boot via cloud-init.
# Moves provisioner files from the FAT32 boot partition to ext4 rootfs,
# installs the auto-provision systemd service, and reboots.
#
# The compressed OS image (.img.xz) is NOT moved — it lives in the raw
# unallocated space on the USB device and provision.sh reads it directly
# from there via dd.
#
# Called by: cloud-init runcmd (see prepare-usb.sh)
# =============================================================================
set -euo pipefail

BOOT_PROV="/boot/firmware/provisioner"
FLAG_FILE="/opt/provisioner/.firstboot-done"
LOG_FILE="/var/log/firstboot-setup.log"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"; }

# --- Guard: only run once ----------------------------------------------------

if [ -f "$FLAG_FILE" ]; then
  log "First boot setup already completed. Skipping."
  exit 0
fi

# --- Validate boot partition files -------------------------------------------

if [ ! -d "$BOOT_PROV" ]; then
  log "ERROR: Provisioner directory not found at $BOOT_PROV"
  exit 1
fi

for required in provision.sh config.env auto-provision.service \
                next-number.txt; do
  if [ ! -f "${BOOT_PROV}/${required}" ]; then
    log "ERROR: Required file missing: ${BOOT_PROV}/${required}"
    exit 1
  fi
done

log "============================================"
log "GreenWare USB — First Boot Setup"
log "============================================"

# --- Move provisioner files to rootfs ----------------------------------------

log "[1/3] Copying provisioner files to rootfs..."

mkdir -p /opt/provisioner/cloud-init

cp "${BOOT_PROV}/provision.sh" /opt/provisioner/
cp "${BOOT_PROV}/config.env" /opt/provisioner/
cp "${BOOT_PROV}/next-number.txt" /opt/provisioner/
chmod +x /opt/provisioner/provision.sh

if [ -d "${BOOT_PROV}/cloud-init" ]; then
  cp "${BOOT_PROV}/cloud-init/"* /opt/provisioner/cloud-init/
fi

log "      Done."

# --- Install systemd service -------------------------------------------------

log "[2/3] Installing auto-provision service..."

cp "${BOOT_PROV}/auto-provision.service" /etc/systemd/system/
systemctl daemon-reload
systemctl enable auto-provision.service

log "      Done."

# --- Mark as complete and reboot ---------------------------------------------

log "[3/3] First boot setup complete!"

touch "$FLAG_FILE"

# Clean up staging directory on boot partition
rm -rf "$BOOT_PROV"

log ""
log "============================================"
log "✅ USB provisioner is configured!"
log "   Rebooting into provisioning mode..."
log "============================================"

sync
sleep 2
reboot
