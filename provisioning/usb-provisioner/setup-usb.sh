#!/bin/bash
# =============================================================================
# GreenWare USB Provisioning Stick Setup
# =============================================================================
# This script prepares a USB stick that has already been flashed with
# Raspberry Pi OS Lite. It copies the provisioner scripts, cloud-init
# templates, target OS image, and config onto the USB stick's rootfs.
#
# Run this from INSIDE a Linux environment (Docker container, Linux VM,
# or a Raspberry Pi) where the USB stick's ext4 rootfs can be mounted.
#
# Usage:
#   ./setup-usb.sh <rootfs-mount> <bootfs-mount> <os-image-path> <config-env-path> [start-number]
#
# Example (Docker):
#   ./setup-usb.sh /mnt/rootfs /mnt/bootfs /work/raspios.img /work/config.env 26
#
# Part of: https://github.com/unredacted/greenware-tools
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# --- Argument Parsing --------------------------------------------------------

if [ $# -lt 4 ]; then
    echo "Usage: $0 <rootfs-mount> <bootfs-mount> <os-image-path> <config-env-path> [start-number]"
    echo ""
    echo "Arguments:"
    echo "  rootfs-mount    Mount point of the USB stick's ext4 root partition"
    echo "  bootfs-mount    Mount point of the USB stick's FAT32 boot partition"
    echo "  os-image-path   Path to the decompressed Raspberry Pi OS .img file"
    echo "  config-env-path Path to your filled-in config.env file"
    echo "  start-number    Starting hostname number (default: 26)"
    echo ""
    echo "Example:"
    echo "  $0 /mnt/rootfs /mnt/bootfs /work/raspios-lite.img /work/config.env 26"
    exit 1
fi

ROOTFS="$1"
BOOTFS="$2"
OS_IMAGE="$3"
CONFIG_ENV="$4"
START_NUM="${5:-26}"

# --- Validation --------------------------------------------------------------

if [ ! -d "$ROOTFS" ]; then
    echo "ERROR: Rootfs mount point does not exist: $ROOTFS"
    exit 1
fi

if [ ! -d "$BOOTFS" ]; then
    echo "ERROR: Bootfs mount point does not exist: $BOOTFS"
    exit 1
fi

if [ ! -f "$OS_IMAGE" ]; then
    echo "ERROR: OS image not found: $OS_IMAGE"
    exit 1
fi

if [ ! -f "$CONFIG_ENV" ]; then
    echo "ERROR: Config file not found: $CONFIG_ENV"
    exit 1
fi

# Check that rootfs looks like a Linux root
if [ ! -d "${ROOTFS}/etc" ] || [ ! -d "${ROOTFS}/opt" ]; then
    echo "ERROR: ${ROOTFS} does not look like a Linux root filesystem"
    echo "       Expected to find /etc and /opt directories"
    exit 1
fi

echo "============================================"
echo "GreenWare USB Provisioner Setup"
echo "============================================"
echo "  Rootfs:       ${ROOTFS}"
echo "  Bootfs:       ${BOOTFS}"
echo "  OS Image:     ${OS_IMAGE}"
echo "  Config:       ${CONFIG_ENV}"
echo "  Start Number: ${START_NUM}"
echo "============================================"
echo ""

# --- Copy Target OS Image ---------------------------------------------------

echo "[1/6] Compressing and copying target OS image to USB stick..."
echo "      This may take a few minutes."
xz -c -T0 "$OS_IMAGE" > "${ROOTFS}/opt/target-image.img.xz"
echo "      Done ($(du -h "${ROOTFS}/opt/target-image.img.xz" | awk '{print $1}') compressed)."

# --- Create Provisioner Directory --------------------------------------------

echo "[2/6] Setting up provisioner directory..."
mkdir -p "${ROOTFS}/opt/provisioner/cloud-init"

# --- Copy Scripts and Templates ----------------------------------------------

echo "[3/6] Copying provisioner scripts and cloud-init templates..."

# Main provisioner script
cp "${REPO_ROOT}/provisioning/usb-provisioner/provision.sh" \
    "${ROOTFS}/opt/provisioner/provision.sh"
chmod +x "${ROOTFS}/opt/provisioner/provision.sh"

# Cloud-init templates
cp "${REPO_ROOT}/provisioning/cloud-init/user-data.template" \
    "${ROOTFS}/opt/provisioner/cloud-init/user-data.template"
cp "${REPO_ROOT}/provisioning/cloud-init/meta-data.template" \
    "${ROOTFS}/opt/provisioner/cloud-init/meta-data.template"
cp "${REPO_ROOT}/provisioning/cloud-init/network-config.template" \
    "${ROOTFS}/opt/provisioner/cloud-init/network-config.template"

# Config file
cp "$CONFIG_ENV" "${ROOTFS}/opt/provisioner/config.env"

echo "      Done."

# --- Initialize Counter File -------------------------------------------------

echo "[4/6] Initializing hostname counter at ${START_NUM}..."
echo "$START_NUM" > "${ROOTFS}/opt/provisioner/next-number.txt"
echo "      Done."

# --- Install Systemd Service -------------------------------------------------

echo "[5/6] Installing auto-provision systemd service..."
cp "${REPO_ROOT}/provisioning/usb-provisioner/auto-provision.service" \
    "${ROOTFS}/etc/systemd/system/auto-provision.service"

# Enable the service (create symlink in multi-user.target.wants)
mkdir -p "${ROOTFS}/etc/systemd/system/multi-user.target.wants"
ln -sf /etc/systemd/system/auto-provision.service \
    "${ROOTFS}/etc/systemd/system/multi-user.target.wants/auto-provision.service"
echo "      Done."

# --- Configure USB Stick's Own First-Boot ------------------------------------

echo "[6/6] Configuring USB stick's own cloud-init (for SSH access)..."

# Source config to get SSH key for the USB stick itself
# shellcheck source=/dev/null
source "$CONFIG_ENV"

# Use a quoted heredoc to avoid issues with special characters in SSH keys,
# then substitute the variables with sed.
cat > "${BOOTFS}/user-data" <<'USERDATA'
#cloud-config
hostname: greenware-provisioner
users:
  - name: __ADMIN_USER__
    groups: [sudo]
    shell: /bin/bash
    sudo: ALL=(ALL) NOPASSWD:ALL
    lock_passwd: true
    ssh_authorized_keys:
      - __SSH_PUBLIC_KEY__
ssh_pwauth: false
USERDATA

sed -i'' \
    -e "s|__ADMIN_USER__|${ADMIN_USER}|g" \
    -e "s|__SSH_PUBLIC_KEY__|${SSH_PUBLIC_KEY}|g" \
    "${BOOTFS}/user-data"

echo "instance-id: greenware-provisioner" > "${BOOTFS}/meta-data"

cat > "${BOOTFS}/network-config" <<'NETCONFIG'
network:
  version: 2
  ethernets:
    eth0:
      dhcp4: true
      optional: true
NETCONFIG

echo "      Done."

# --- Summary -----------------------------------------------------------------

sync

echo ""
echo "============================================"
echo "USB provisioning stick is ready!"
echo "============================================"
echo ""
echo "The USB stick will:"
echo "  1. Boot on a Pi (when microSD has no valid OS)"
echo "  2. Auto-flash Raspberry Pi OS to the microSD card"
echo "  3. Inject cloud-init config with hostname #${START_NUM}"
echo "  4. Increment the counter for the next unit"
echo ""
echo "Next steps:"
echo "  1. Unmount and safely eject the USB stick:"
echo "     sync && umount ${BOOTFS} ${ROOTFS}"
echo "  2. Insert a blank microSD into a Pi"
echo "  3. Plug in the USB stick and connect PoE Ethernet"
echo "  4. Wait for rapid LED blink = done"
echo "============================================"
