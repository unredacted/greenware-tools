#!/bin/bash
# =============================================================================
# GreenWare USB Provisioner — One-Step Setup (macOS + Linux)
# =============================================================================
# Prepares a USB-A stick as a self-contained Raspberry Pi provisioner.
#
# USB Layout after this script:
#   Partition 1 — FAT32  "bootfs"   — Pi boot files + provisioner scripts
#   Partition 2 — ext4   "rootfs"   — Pi OS (growpart will expand this)
#   Partition 3 — FAT32  "GWDATA"   — Compressed OS image (.img.xz)
#
# No Docker required. Works on macOS and Linux.
# =============================================================================
set -euo pipefail

# Debug helper: prints commands before they run for easier troubleshooting
dbg() { echo "      [DBG] ▶ $*"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# --- Detect OS ---------------------------------------------------------------

OS_TYPE="$(uname -s)"
case "$OS_TYPE" in
  Darwin) PLATFORM="macos" ;;
  Linux)  PLATFORM="linux" ;;
  *)
    echo "ERROR: Unsupported operating system: $OS_TYPE"
    exit 1
    ;;
esac

# --- Load Config -------------------------------------------------------------

CONFIG_FILE="${1:-${REPO_ROOT}/provisioning/config.env}"

if [ ! -f "$CONFIG_FILE" ]; then
  echo "ERROR: Config file not found: $CONFIG_FILE"
  echo "  cp provisioning/config.env.example provisioning/config.env"
  exit 1
fi

# shellcheck source=/dev/null
source "$CONFIG_FILE"

for var in TAILSCALE_AUTH_KEY HEADSCALE_URL HOSTNAME_PREFIX HOSTNAME_SUFFIX \
           SSH_PUBLIC_KEY ADMIN_USER OS_IMAGE USB_DISK HOSTNAME_START; do
  if [ -z "${!var:-}" ]; then
    echo "ERROR: Required variable $var is not set in $CONFIG_FILE"
    exit 1
  fi
done

# --- Locate OS Image ---------------------------------------------------------

IMAGE_PATH=""
if [ -f "$OS_IMAGE" ]; then
  IMAGE_PATH="$(cd "$(dirname "$OS_IMAGE")" && pwd)/$(basename "$OS_IMAGE")"
elif [ -f "${REPO_ROOT}/${OS_IMAGE}" ]; then
  IMAGE_PATH="${REPO_ROOT}/${OS_IMAGE}"
else
  echo "ERROR: OS image not found: $OS_IMAGE"
  echo "       Download from: https://downloads.raspberrypi.com/raspios_lite_arm64/images/"
  exit 1
fi

IMAGE_IS_XZ=false
case "$IMAGE_PATH" in
  *.xz)  IMAGE_IS_XZ=true ;;
  *.img) IMAGE_IS_XZ=false ;;
  *)     echo "ERROR: OS_IMAGE must be a .img or .img.xz file"; exit 1 ;;
esac

if ! command -v xz &>/dev/null; then
  echo "ERROR: 'xz' command not found."
  exit 1
fi

# --- Derive Disk Paths -------------------------------------------------------

if [ "$PLATFORM" = "macos" ]; then
  # shellcheck disable=SC2153
  USB_RDISK="${USB_DISK/disk/rdisk}"
  DD_TARGET="$USB_RDISK"
  DD_BS="4m"
else
  DD_TARGET="$USB_DISK"
  DD_BS="4M"
fi

# --- Drive Safety Validation -------------------------------------------------

echo ""
echo "Validating target disk ${USB_DISK}..."

if [ ! -b "$USB_DISK" ]; then
  echo "ERROR: ${USB_DISK} is not a valid block device."
  exit 1
fi

if [ "$PLATFORM" = "macos" ]; then
  DISK_NUM="${USB_DISK##*/disk}"
  if [ "$DISK_NUM" = "0" ] || [ "$DISK_NUM" = "1" ]; then
    echo "FATAL: ${USB_DISK} is the macOS system disk!"
    exit 1
  fi
  if diskutil info "$USB_DISK" 2>/dev/null | grep -qi "APFS\|Macintosh HD\|Apple_APFS"; then
    echo "FATAL: ${USB_DISK} contains APFS/macOS partitions!"
    exit 1
  fi
  DISK_INTERNAL=$(diskutil info "$USB_DISK" 2>/dev/null | grep -i "Internal:" | awk '{print $NF}' || true)
  DISK_REMOVABLE=$(diskutil info "$USB_DISK" 2>/dev/null | grep -i "Removable Media:" | awk '{print $NF}' || true)
  if [ "$DISK_INTERNAL" = "Yes" ] && [ "$DISK_REMOVABLE" != "Removable" ]; then
    echo "FATAL: ${USB_DISK} is an internal, non-removable disk!"
    exit 1
  fi
elif [ "$PLATFORM" = "linux" ]; then
  ROOT_CHECK=$(lsblk -no MOUNTPOINT "$USB_DISK" 2>/dev/null | grep -c "^/$" || true)
  if [ "$ROOT_CHECK" -gt 0 ]; then
    echo "FATAL: ${USB_DISK} contains the root filesystem (/)!"
    exit 1
  fi
  DEV_NAME="${USB_DISK##*/}"
  REMOVABLE_FLAG="/sys/block/${DEV_NAME}/removable"
  if [ -f "$REMOVABLE_FLAG" ] && [ "$(cat "$REMOVABLE_FLAG")" = "0" ]; then
    DEVPATH=$(readlink -f "/sys/block/${DEV_NAME}" 2>/dev/null || true)
    if [[ "$DEVPATH" != *"/usb"* ]]; then
      echo "FATAL: ${USB_DISK} is not a removable/USB drive!"
      exit 1
    fi
  fi
fi

DISK_SIZE_BYTES=0
if [ "$PLATFORM" = "macos" ]; then
  DISK_SIZE_BYTES=$(diskutil info "$USB_DISK" 2>/dev/null | grep "Disk Size:" | grep -oE '[0-9]+ Bytes' | awk '{print $1}' || true)
  DISK_SIZE_BYTES="${DISK_SIZE_BYTES:-0}"
elif [ "$PLATFORM" = "linux" ]; then
  DISK_SIZE_BYTES=$(blockdev --getsize64 "$USB_DISK" 2>/dev/null || echo "0")
fi

MIN_SIZE=$((4 * 1024 * 1024 * 1024))
MAX_SIZE=$((256 * 1024 * 1024 * 1024))

if [ "${DISK_SIZE_BYTES:-0}" -gt 0 ]; then
  DISK_SIZE_GB=$(( DISK_SIZE_BYTES / 1024 / 1024 / 1024 ))
  if [ "$DISK_SIZE_BYTES" -lt "$MIN_SIZE" ]; then
    echo "FATAL: ${USB_DISK} is only ${DISK_SIZE_GB} GB — too small."
    exit 1
  fi
  if [ "$DISK_SIZE_BYTES" -gt "$MAX_SIZE" ]; then
    echo "FATAL: ${USB_DISK} is ${DISK_SIZE_GB} GB — too large."
    exit 1
  fi
  echo "  ✅ Disk size: ${DISK_SIZE_GB} GB"
fi
echo "  ✅ Disk is external/removable"
echo "  ✅ Disk is not a system drive"

# --- Safety Confirmation -----------------------------------------------------

echo ""
echo "============================================"
echo "GreenWare USB Provisioner — One-Step Setup"
echo "============================================"
echo ""
echo "  Platform:     ${PLATFORM}"
echo "  OS Image:     ${IMAGE_PATH}"
echo "  USB Disk:     ${USB_DISK}"
echo "  Start Number: ${HOSTNAME_START}"
echo "  Hostname:     ${HOSTNAME_PREFIX}${HOSTNAME_START}${HOSTNAME_SUFFIX}"
echo ""

echo "  --- Disk Details ---"
if [ "$PLATFORM" = "macos" ]; then
  diskutil info "$USB_DISK" 2>/dev/null | grep -E "Device / Media Name:|Disk Size:|Device Location:|Removable Media:" | sed 's/^/  /' || true
else
  lsblk -o NAME,SIZE,TYPE,TRAN,MODEL,MOUNTPOINT "$USB_DISK" 2>/dev/null | sed 's/^/  /' || true
fi
echo ""

echo "⚠️  WARNING: This will PERMANENTLY ERASE ${USB_DISK}!"
echo ""
echo "   To confirm, type the disk identifier exactly: ${USB_DISK}"
echo ""
read -rp "Disk identifier: " CONFIRM_DISK
if [ "$CONFIRM_DISK" != "$USB_DISK" ]; then
  echo "Aborted."
  exit 0
fi

# =============================================================================
# Step 1: Flash OS image to USB stick
# =============================================================================

echo ""
echo "[1/5] Flashing OS image to USB stick..."
echo "      This may take a few minutes."

if [ "$PLATFORM" = "macos" ]; then
  dbg "diskutil unmountDisk force $USB_DISK"
  diskutil unmountDisk force "$USB_DISK" 2>/dev/null || true
  if [ "$IMAGE_IS_XZ" = true ]; then
    echo "      Decompressing and flashing (xz → dd)..."
    dbg "xz -dc $IMAGE_PATH | sudo dd of=$DD_TARGET bs=$DD_BS"
    xz -dc "$IMAGE_PATH" | sudo dd of="$DD_TARGET" bs="$DD_BS"
  else
    dbg "sudo dd if=$IMAGE_PATH of=$DD_TARGET bs=$DD_BS"
    sudo dd if="$IMAGE_PATH" of="$DD_TARGET" bs="$DD_BS"
  fi
else
  for part in "${USB_DISK}"*; do
    dbg "umount $part"
    umount "$part" 2>/dev/null || true
  done
  if [ "$IMAGE_IS_XZ" = true ]; then
    echo "      Decompressing and flashing (xz → dd)..."
    dbg "xz -dc $IMAGE_PATH | dd of=$DD_TARGET bs=$DD_BS conv=fsync"
    xz -dc "$IMAGE_PATH" | dd of="$DD_TARGET" bs="$DD_BS" conv=fsync
  else
    dbg "dd if=$IMAGE_PATH of=$DD_TARGET bs=$DD_BS status=progress conv=fsync"
    dd if="$IMAGE_PATH" of="$DD_TARGET" bs="$DD_BS" status=progress conv=fsync
  fi
fi
dbg "sync"
sync
echo "      Flash complete."

# =============================================================================
# Step 2: Create FAT32 data partition (partition 3) for the OS image
# =============================================================================

echo ""
echo "[2/5] Creating data partition for OS image..."

# Helper: read a 4-byte little-endian unsigned integer from a file
read_le32() {
  local file=$1 offset=$2
  local hex
  hex=$(od -An -j "$offset" -N 4 -tx1 "$file" | tr -d ' \n')
  local b0=${hex:0:2} b1=${hex:2:2} b2=${hex:4:2} b3=${hex:6:2}
  echo $(( 16#${b3} * 16777216 + 16#${b2} * 65536 + 16#${b1} * 256 + 16#${b0} ))
}

if [ "$PLATFORM" = "macos" ]; then
  dbg "diskutil unmountDisk force $USB_DISK"
  diskutil unmountDisk force "$USB_DISK" 2>/dev/null || true

  # Read the MBR (sector 0) from the USB stick
  MBR_TMP=$(mktemp /tmp/greenware-mbr.XXXXXX)
  trap 'rm -f "$MBR_TMP"' EXIT
  dbg "dd if=$USB_RDISK of=$MBR_TMP bs=512 count=1"
  if ! sudo dd if="$USB_RDISK" of="$MBR_TMP" bs=512 count=1 2>&1; then
    echo "ERROR: Failed to read MBR from ${USB_RDISK}."
    echo "       The disk may have been re-enumerated by macOS after the flash."
    echo "       Check 'diskutil list' and update USB_DISK in config.env if needed."
    exit 1
  fi

  # Validate the MBR was read correctly
  MBR_SIZE=$(stat -f%z "$MBR_TMP" 2>/dev/null || echo "0")
  if [ "$MBR_SIZE" -ne 512 ]; then
    echo "ERROR: MBR read failed (got ${MBR_SIZE} bytes, expected 512)"
    exit 1
  fi

  # Check for valid MBR boot signature (bytes 510-511 = 0x55AA)
  BOOT_SIG=$(od -An -j 510 -N 2 -tx1 "$MBR_TMP" | tr -d ' \n')
  dbg "MBR boot signature: 0x${BOOT_SIG}"
  if [ "$BOOT_SIG" != "55aa" ]; then
    echo "ERROR: Invalid MBR boot signature: 0x${BOOT_SIG} (expected 0x55aa)"
    echo "       The USB may not have been flashed correctly."
    exit 1
  fi

  # Parse partition 2 entry (bytes 462-477 in the MBR)
  # Bytes 470-473: LBA start (little-endian uint32)
  # Bytes 474-477: Total sectors (little-endian uint32)
  P2_START=$(read_le32 "$MBR_TMP" 470)
  P2_SIZE=$(read_le32 "$MBR_TMP" 474)
  dbg "P2_START=$P2_START P2_SIZE=$P2_SIZE (sectors)"

  # Validate partition 2 looks reasonable
  if [ "$P2_START" -eq 0 ] || [ "$P2_SIZE" -eq 0 ]; then
    echo "ERROR: Partition 2 not found in MBR (start=${P2_START}, size=${P2_SIZE})"
    echo "       The OS image may not have a standard Pi OS partition layout."
    exit 1
  fi

  P3_START=$((P2_START + P2_SIZE))
  DISK_SECTORS=$((DISK_SIZE_BYTES / 512))
  P3_SIZE=$((DISK_SECTORS - P3_START))

  # Safety: partition 3 must start AFTER partition 2 and have positive size
  if [ "$P3_START" -le "$P2_START" ]; then
    echo "ERROR: Calculated P3 start (${P3_START}) is not after P2 start (${P2_START})"
    exit 1
  fi
  if [ "$P3_SIZE" -le 0 ]; then
    echo "ERROR: No space left on disk for partition 3"
    exit 1
  fi

  echo "      Partition 2: sectors ${P2_START}–$((P2_START + P2_SIZE))"
  echo "      Partition 3: sectors ${P3_START}–$((P3_START + P3_SIZE)) ($(( P3_SIZE * 512 / 1024 / 1024 )) MB)"

  # Write partition entry 3 at bytes 478-493 in the MBR:
  #   Byte  478:     Status = 0x00 (inactive)
  #   Bytes 479-481: CHS first = FE FF FF (LBA mode)
  #   Byte  482:     Type = 0x0C (FAT32 LBA)
  #   Bytes 483-485: CHS last = FE FF FF (LBA mode)
  #   Bytes 486-489: LBA start (little-endian)
  #   Bytes 490-493: Size in sectors (little-endian)

  # Status + CHS + Type + CHS (8 bytes)
  printf '\x00\xfe\xff\xff\x0c\xfe\xff\xff' | \
    dd of="$MBR_TMP" bs=1 seek=478 conv=notrunc 2>/dev/null

  # Helper: write 4-byte little-endian uint32 to a file at a given offset
  write_le32() {
    local file=$1 offset=$2 value=$3
    # shellcheck disable=SC2059
    printf "$(printf '\\x%02x\\x%02x\\x%02x\\x%02x' \
      $((value & 0xFF)) \
      $(((value >> 8) & 0xFF)) \
      $(((value >> 16) & 0xFF)) \
      $(((value >> 24) & 0xFF)))" | \
      dd of="$file" bs=1 seek="$offset" conv=notrunc 2>/dev/null
  }

  # LBA start (4 bytes, little-endian)
  write_le32 "$MBR_TMP" 486 "$P3_START"

  # Size in sectors (4 bytes, little-endian)
  write_le32 "$MBR_TMP" 490 "$P3_SIZE"

  # Write the modified MBR back to the USB
  dbg "diskutil unmountDisk force $USB_DISK"
  diskutil unmountDisk force "$USB_DISK" 2>/dev/null || true
  dbg "dd if=$MBR_TMP of=$USB_RDISK bs=512 count=1 conv=notrunc"
  sudo dd if="$MBR_TMP" of="$USB_RDISK" bs=512 count=1 conv=notrunc 2>/dev/null
  rm -f "$MBR_TMP"
  trap - EXIT

  # macOS needs a moment to re-read the partition table
  sleep 3

  echo "      --- Partition table after MBR update ---"
  diskutil list "$USB_DISK" 2>/dev/null | sed 's/^/      /' || true

  # Format partition 3 as FAT32
  P3_DEV="${USB_DISK}s3"
  echo "      Formatting ${P3_DEV} as FAT32..."

  # Verify partition 3 device exists before formatting
  if ! diskutil info "$P3_DEV" &>/dev/null; then
    echo "ERROR: Partition ${P3_DEV} not recognized by macOS."
    echo "       The MBR update may not have been picked up. Try re-running."
    exit 1
  fi

  # macOS may auto-mount the new partition — unmount before formatting
  dbg "diskutil unmountDisk force $USB_DISK"
  diskutil unmountDisk force "$USB_DISK" 2>/dev/null || true

  dbg "newfs_msdos -F 32 -v GWDATA /dev/${P3_DEV##*/}"
  sudo newfs_msdos -F 32 -v GWDATA "/dev/${P3_DEV##*/}"
  sleep 2

  # Mount it
  dbg "diskutil mount ${USB_DISK}s3"
  diskutil mount "${USB_DISK}s3" 2>/dev/null || true
  sleep 2

  DATA_MOUNT=""
  for _attempt in $(seq 1 10); do
    DATA_MOUNT=$(diskutil info "${USB_DISK}s3" 2>/dev/null | grep "Mount Point:" | sed 's/.*Mount Point:[[:space:]]*//' || true)
    if [ -n "$DATA_MOUNT" ] && [ -d "$DATA_MOUNT" ]; then
      break
    fi
    sleep 2
    diskutil mount "${USB_DISK}s3" 2>/dev/null || true
  done

  if [ -z "$DATA_MOUNT" ] || [ ! -d "$DATA_MOUNT" ]; then
    echo "ERROR: Could not mount data partition ${USB_DISK}s3"
    exit 1
  fi

else
  # Linux: use sfdisk to add partition 3
  # Get the end of partition 2
  P2_END=$(sfdisk -l "$USB_DISK" 2>/dev/null | awk '/'"${USB_DISK}"'.*Linux/ {print $2 + $3}' || true)
  if [ -z "$P2_END" ] || [ "$P2_END" = "0" ]; then
    # Fallback: use fdisk
    P2_END=$(fdisk -l "$USB_DISK" 2>/dev/null | awk '/'"${USB_DISK}"'2/ {print $3 + 1}' || true)
  fi

  echo "      Creating partition 3 starting at sector ${P2_END}..."
  dbg "echo 'start=${P2_END}, type=c' | sfdisk --append $USB_DISK"
  echo "start=${P2_END}, type=c" | sfdisk --append "$USB_DISK" 2>/dev/null
  dbg "partprobe $USB_DISK"
  partprobe "$USB_DISK" 2>/dev/null || true
  sleep 2

  # Detect partition 3 device name
  DATA_PART=""
  if [ -b "${USB_DISK}3" ]; then
    DATA_PART="${USB_DISK}3"
  elif [ -b "${USB_DISK}p3" ]; then
    DATA_PART="${USB_DISK}p3"
  else
    echo "ERROR: Could not find data partition on ${USB_DISK}"
    exit 1
  fi

  echo "      Formatting partition 3 as FAT32..."
  dbg "mkfs.vfat -F 32 -n GWDATA $DATA_PART"
  mkfs.vfat -F 32 -n GWDATA "$DATA_PART"
  sleep 1

  DATA_MOUNT=$(mktemp -d)
  dbg "mount $DATA_PART $DATA_MOUNT"
  mount "$DATA_PART" "$DATA_MOUNT"
fi

echo "      Data partition mounted at: $DATA_MOUNT"

# =============================================================================
# Step 3: Copy OS image to data partition
# =============================================================================

echo ""
echo "[3/5] Copying OS image to data partition..."

if [ "$IMAGE_IS_XZ" = true ]; then
  echo "      Copying .img.xz (this may take a minute)..."
  dbg "cp $IMAGE_PATH ${DATA_MOUNT}/target-image.img.xz"
  cp "$IMAGE_PATH" "${DATA_MOUNT}/target-image.img.xz"
else
  echo "      Compressing and copying .img → .img.xz (this may take several minutes)..."
  dbg "xz -c -T0 $IMAGE_PATH > ${DATA_MOUNT}/target-image.img.xz"
  xz -c -T0 "$IMAGE_PATH" > "${DATA_MOUNT}/target-image.img.xz"
fi
dbg "sync"
sync
echo "      Done ($(du -h "${DATA_MOUNT}/target-image.img.xz" | awk '{print $1}'))."

# Unmount data partition (we're done with it)
if [ "$PLATFORM" = "macos" ]; then
  dbg "diskutil unmount ${USB_DISK}s3"
  diskutil unmount "${USB_DISK}s3" 2>/dev/null || true
else
  umount "$DATA_MOUNT"
  rmdir "$DATA_MOUNT" 2>/dev/null || true
fi

# =============================================================================
# Step 4: Copy provisioner files to boot partition (FAT32)
# =============================================================================

echo ""
echo "[4/5] Copying provisioner files to boot partition..."

if [ "$PLATFORM" = "macos" ]; then
  sleep 2
  dbg "diskutil mount ${USB_DISK}s1"
  diskutil mount "${USB_DISK}s1" 2>/dev/null || true
  sleep 2

  BOOT_MOUNT=""
  for _attempt in $(seq 1 10); do
    BOOT_MOUNT=$(diskutil info "${USB_DISK}s1" 2>/dev/null | grep "Mount Point:" | sed 's/.*Mount Point:[[:space:]]*//' || true)
    if [ -n "$BOOT_MOUNT" ] && [ -d "$BOOT_MOUNT" ]; then
      break
    fi
    sleep 2
    diskutil mount "${USB_DISK}s1" 2>/dev/null || true
  done

  if [ -z "$BOOT_MOUNT" ] || [ ! -d "$BOOT_MOUNT" ]; then
    echo "ERROR: Could not mount boot partition ${USB_DISK}s1"
    exit 1
  fi
else
  sleep 2
  partprobe "$USB_DISK" 2>/dev/null || true
  sleep 1

  BOOT_PART=""
  if [ -b "${USB_DISK}1" ]; then
    BOOT_PART="${USB_DISK}1"
  elif [ -b "${USB_DISK}p1" ]; then
    BOOT_PART="${USB_DISK}p1"
  else
    echo "ERROR: Could not find boot partition on ${USB_DISK}"
    exit 1
  fi

  BOOT_MOUNT=$(mktemp -d)
  trap 'umount "$BOOT_MOUNT" 2>/dev/null || true; rmdir "$BOOT_MOUNT" 2>/dev/null || true' EXIT
  dbg "mount $BOOT_PART $BOOT_MOUNT"
  mount "$BOOT_PART" "$BOOT_MOUNT"
fi

echo "      Boot partition mounted at: $BOOT_MOUNT"

PROV_DIR="${BOOT_MOUNT}/provisioner"
dbg "mkdir -p ${PROV_DIR}/cloud-init"
mkdir -p "${PROV_DIR}/cloud-init"

dbg "cp provision.sh firstboot-setup.sh auto-provision.service config.env → ${PROV_DIR}/"
cp "${SCRIPT_DIR}/provision.sh" "${PROV_DIR}/"
cp "${SCRIPT_DIR}/firstboot-setup.sh" "${PROV_DIR}/"
cp "${SCRIPT_DIR}/auto-provision.service" "${PROV_DIR}/"
cp "$CONFIG_FILE" "${PROV_DIR}/config.env"

dbg "cp cloud-init templates → ${PROV_DIR}/cloud-init/"
cp "${REPO_ROOT}/provisioning/cloud-init/user-data.template" "${PROV_DIR}/cloud-init/"
cp "${REPO_ROOT}/provisioning/cloud-init/meta-data.template" "${PROV_DIR}/cloud-init/"
cp "${REPO_ROOT}/provisioning/cloud-init/network-config.template" "${PROV_DIR}/cloud-init/"

dbg "echo ${HOSTNAME_START} > ${PROV_DIR}/next-number.txt"
echo "${HOSTNAME_START}" > "${PROV_DIR}/next-number.txt"

# Enable USB boot on PoE / non-5V5A power supplies
if ! grep -q 'usb_max_current_enable=1' "${BOOT_MOUNT}/config.txt" 2>/dev/null; then
  dbg "Appending usb_max_current_enable=1 to ${BOOT_MOUNT}/config.txt"
  {
    echo ""
    echo "# Allow USB boot on PoE (non-5V/5A) power supplies"
    echo "usb_max_current_enable=1"
  } >> "${BOOT_MOUNT}/config.txt"
fi

echo "      All provisioner files copied."
echo "      --- Boot partition contents ---"
find "${PROV_DIR}" -type f -exec stat -f '      %z  %N' {} \; 2>/dev/null || \
  find "${PROV_DIR}" -type f -printf '      %s  %p\n' 2>/dev/null || true

# =============================================================================
# Step 5: Write cloud-init for USB stick's first boot
# =============================================================================

echo ""
echo "[5/5] Configuring USB stick first-boot..."

# Write cloud-init user-data directly with variable expansion (no sed needed).
# Note: using unquoted USERDATA delimiter so bash expands variables.
dbg "Writing user-data with ADMIN_USER=${ADMIN_USER}, SSH_PUBLIC_KEY=(${#SSH_PUBLIC_KEY} chars)"
cat > "${BOOT_MOUNT}/user-data" <<USERDATA
#cloud-config
hostname: greenware-provisioner

users:
  - name: ${ADMIN_USER}
    groups: [sudo]
    shell: /bin/bash
    sudo: ALL=(ALL) NOPASSWD:ALL
    lock_passwd: true
    ssh_authorized_keys:
      - ${SSH_PUBLIC_KEY}

ssh_pwauth: false

growpart:
  mode: auto
  devices: ["/"]

resize_rootfs: true

runcmd:
  - bash /boot/firmware/provisioner/firstboot-setup.sh
USERDATA

echo "instance-id: greenware-provisioner" > "${BOOT_MOUNT}/meta-data"

cat > "${BOOT_MOUNT}/network-config" <<'NETCONFIG'
network:
  version: 2
  ethernets:
    eth0:
      dhcp4: true
      optional: true
NETCONFIG

echo "      Cloud-init configured (growpart enabled — partition 3 protects data)."
echo "      --- Cloud-init files written ---"
for f in user-data meta-data network-config; do
  if [ -f "${BOOT_MOUNT}/${f}" ]; then
    echo "      ${f}: $(wc -c < "${BOOT_MOUNT}/${f}" | tr -d ' ') bytes"
  fi
done

# --- Sync and Eject ----------------------------------------------------------

dbg "sync"
sync

if [ "$PLATFORM" = "macos" ]; then
  echo ""
  echo "Ejecting USB stick..."
  dbg "diskutil eject $USB_DISK"
  diskutil eject "$USB_DISK"
else
  dbg "umount $BOOT_MOUNT"
  umount "$BOOT_MOUNT"
  rmdir "$BOOT_MOUNT" 2>/dev/null || true
  trap - EXIT
  sync
  dbg "eject $USB_DISK"
  eject "$USB_DISK" 2>/dev/null || udisksctl power-off -b "$USB_DISK" 2>/dev/null || echo "Done (remove USB stick manually)."
fi

echo ""
echo "============================================"
echo "✅ USB provisioner is ready!"
echo "============================================"
echo ""
echo "IMPORTANT: One-time first boot required!"
echo ""
echo "  1. Plug the USB into any Pi (no microSD needed)"
echo "  2. Connect power and wait ~2 minutes"
echo "  3. The Pi sets up the provisioner and reboots"
echo "  4. Power off — the USB is now ready!"
echo ""
echo "Provisioning workflow (repeat for each Pi):"
echo "  1. Insert a blank microSD into a Pi"
echo "  2. Plug in the USB stick"
echo "  3. Connect power (PoE or USB-C)"
echo "  4. Wait for rapid LED blink → Pi powers off"
echo "  5. Remove USB stick, reconnect power"
echo "  6. Pi boots from SD and joins your tailnet"
echo ""
echo "Starting hostname: ${HOSTNAME_PREFIX}${HOSTNAME_START}${HOSTNAME_SUFFIX}"
echo "============================================"
