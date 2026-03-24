#!/bin/bash
# Assemble bootable SD card for Orange Pi 3 LTS (32-bit AArch32 boot chain)
#
# Layout:
#   0x0000           MBR + partition table
#   0x2000 (8 KB)    U-Boot SPL (AArch32) with eGON header
#   0x100000 (1 MB)  Partition 1 (ext4)
#                    ├── /boot/zImage
#                    ├── /boot/sun50i-h6-orangepi-3.dtb
#                    ├── /boot/boot.scr
#                    └── rootfs...
set -euo pipefail

WORK="${WORK:-$HOME/opi3-build}"

if [ $# -lt 1 ]; then
    echo "Usage: $0 /dev/sdX"
    echo ""
    echo "WARNING: This will ERASE the entire target device!"
    exit 1
fi

SD="$1"

# Safety checks
if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: Must be run as root"
    exit 1
fi

if [ ! -b "$SD" ]; then
    echo "ERROR: $SD is not a block device"
    exit 1
fi

# Prevent accidental writes to system disks
case "$SD" in
    /dev/sda|/dev/nvme0n1|/dev/vda|/dev/mmcblk0)
        echo "ERROR: Refusing to write to $SD (looks like a system disk)"
        exit 1
        ;;
esac

# Check required files
UBOOT="$WORK/output/u-boot-sunxi-with-spl-arm32.bin"
ZIMAGE="$WORK/output/zImage"
ROOTFS="$WORK/rootfs"

for f in "$UBOOT" "$ZIMAGE"; do
    if [ ! -f "$f" ]; then
        echo "ERROR: Required file not found: $f"
        echo "Run build-uboot-arm32.sh and build-kernel-arm32.sh first."
        exit 1
    fi
done

if [ ! -d "$ROOTFS/bin" ]; then
    echo "ERROR: Rootfs not found or incomplete at $ROOTFS"
    echo "Run create-rootfs.sh first."
    exit 1
fi

# Read DTB name
if [ -f "$WORK/output/dtb-name.txt" ]; then
    DTB_NAME=$(cat "$WORK/output/dtb-name.txt")
else
    if [ -f "$WORK/output/sun50i-h6-orangepi-3-lts.dtb" ]; then
        DTB_NAME=sun50i-h6-orangepi-3-lts.dtb
    else
        DTB_NAME=sun50i-h6-orangepi-3.dtb
    fi
fi

DTB="$WORK/output/$DTB_NAME"
if [ ! -f "$DTB" ]; then
    echo "ERROR: DTB not found: $DTB"
    exit 1
fi

# Generate boot.scr for 32-bit boot (bootz instead of booti)
BOOT_SCR="$WORK/output/boot-arm32.scr"
echo "Generating 32-bit boot.scr..."
cat > "$WORK/output/boot-arm32.cmd" << BOOTCMD
setenv bootargs console=ttyS0,115200 earlycon=uart8250,mmio32,0x05000000 root=LABEL=rootfs rootfstype=ext4 rootwait rw panic=10 loglevel=7
if load mmc 0:1 0x42000000 /boot/zImage; then
  load mmc 0:1 0x44000000 /boot/$DTB_NAME
else
  load mmc 1:1 0x42000000 /boot/zImage
  load mmc 1:1 0x44000000 /boot/$DTB_NAME
fi
bootz 0x42000000 - 0x44000000
BOOTCMD
mkimage -C none -A arm -T script -d "$WORK/output/boot-arm32.cmd" "$BOOT_SCR"

echo ""
echo "========================================="
echo "  SD Card Assembly (32-bit AArch32)"
echo "========================================="
echo "  Target:     $SD"
echo "  Bootloader: $UBOOT"
echo "  Kernel:     $ZIMAGE (32-bit zImage)"
echo "  DTB:        $DTB"
echo "  Rootfs:     $ROOTFS"
echo "========================================="
echo ""
echo "ALL DATA ON $SD WILL BE DESTROYED!"
read -p "Type YES to continue: " CONFIRM
if [ "$CONFIRM" != "YES" ]; then
    echo "Aborted."
    exit 1
fi

# Unmount any existing partitions
echo "Unmounting any mounted partitions..."
umount "${SD}"* 2>/dev/null || true

# Wipe beginning of disk
echo "Wiping disk header..."
dd if=/dev/zero of="$SD" bs=1M count=16 status=progress

# Create partition table
echo "Creating partition table..."
parted -s "$SD" mklabel msdos
parted -s "$SD" mkpart primary ext4 1MiB 100%

# Write bootloader at 8KB offset (same as 64-bit, same BROM expectations)
echo "Writing 32-bit bootloader..."
dd if="$UBOOT" of="$SD" bs=1024 seek=8 conv=notrunc status=progress

# Detect partition device name
sleep 1
if [ -b "${SD}1" ]; then
    PART="${SD}1"
elif [ -b "${SD}p1" ]; then
    PART="${SD}p1"
else
    echo "ERROR: Cannot find partition 1 on $SD"
    echo "Try: partprobe $SD"
    exit 1
fi

# Format
echo "Formatting $PART as ext4..."
mkfs.ext4 -L rootfs -F "$PART"

# Mount and populate
MNT="$WORK/mnt"
mkdir -p "$MNT"
mount "$PART" "$MNT"

echo "Copying rootfs (this takes a while)..."
cp -a "$ROOTFS"/* "$MNT"/

# Install boot files
echo "Installing boot files..."
mkdir -p "$MNT/boot"
cp "$ZIMAGE" "$MNT/boot/"
cp "$DTB" "$MNT/boot/"
cp "$BOOT_SCR" "$MNT/boot/boot.scr"

# Sync and unmount
echo "Syncing..."
sync
umount "$MNT"

echo ""
echo "========================================="
echo "  SD card assembly complete! (32-bit)"
echo "========================================="
echo ""
echo "Insert into Orange Pi 3 LTS and connect serial console:"
echo "  screen /dev/ttyUSB0 115200"
echo ""
echo "Expected boot sequence:"
echo "  BROM (AArch32) -> SPL (AArch32) -> U-Boot (AArch32) -> zImage (AArch32)"
echo "  No RMR switch, no TF-A, no warm reset."
echo ""
echo "Default login: root / orangepi"
echo ""
echo "NOTE: Initially boots single-core. See docs/h6-32bit-research.md for SMP."
