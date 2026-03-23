#!/bin/bash
# Assemble bootable SD card for Orange Pi 3 LTS
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

# Check required files exist
UBOOT="$WORK/output/u-boot-sunxi-with-spl.bin"
IMAGE="$WORK/output/Image"
ROOTFS="$WORK/rootfs"

for f in "$UBOOT" "$IMAGE"; do
    if [ ! -f "$f" ]; then
        echo "ERROR: Required file not found: $f"
        exit 1
    fi
done

if [ ! -d "$ROOTFS/bin" ]; then
    echo "ERROR: Rootfs not found or incomplete at $ROOTFS"
    exit 1
fi

# Read DTB name
if [ -f "$WORK/output/dtb-name.txt" ]; then
    DTB_NAME=$(cat "$WORK/output/dtb-name.txt")
else
    # Fallback detection
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

# Generate boot.scr if not present
BOOT_SCR="$WORK/output/boot.scr"
if [ ! -f "$BOOT_SCR" ]; then
    echo "Generating boot.scr..."
    cat > "$WORK/output/boot.cmd" << BOOTCMD
setenv bootargs console=ttyS0,115200 root=/dev/mmcblk0p1 rootfstype=ext4 rootwait rw panic=10 loglevel=7
load mmc 0:1 \${kernel_addr_r} /boot/Image
load mmc 0:1 \${fdt_addr_r} /boot/allwinner/$DTB_NAME
booti \${kernel_addr_r} - \${fdt_addr_r}
BOOTCMD
    mkimage -C none -A arm64 -T script -d "$WORK/output/boot.cmd" "$BOOT_SCR"
fi

echo ""
echo "========================================="
echo "  SD Card Assembly"
echo "========================================="
echo "  Target:     $SD"
echo "  Bootloader: $UBOOT"
echo "  Kernel:     $IMAGE"
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

# Write bootloader at 8KB offset
echo "Writing bootloader..."
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
mkdir -p "$MNT/boot/allwinner"
cp "$IMAGE" "$MNT/boot/"
cp "$DTB" "$MNT/boot/allwinner/"
cp "$BOOT_SCR" "$MNT/boot/"

# Sync and unmount
echo "Syncing..."
sync
umount "$MNT"

echo ""
echo "========================================="
echo "  SD card assembly complete!"
echo "========================================="
echo ""
echo "Insert into Orange Pi 3 LTS and connect serial console:"
echo "  screen /dev/ttyUSB0 115200"
echo ""
echo "Default login: root / orangepi"
