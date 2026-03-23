#!/bin/bash
# Build complete bootable SD card image for Orange Pi 3 LTS (AArch32)
# Version 2: Uses native ARM64 Docker + downloads pre-built rootfs
set -euo pipefail

WORK="${WORK:-/build}"
CROSS="arm-linux-gnueabihf-"
KERNEL_VER="v6.6.70"
IMG_SIZE_MB=2048
IMG="$WORK/output/opi3-lts-arm32.img"

echo "============================================"
echo "  Orange Pi 3 LTS - Full 32-bit Image Build"
echo "============================================"
echo "  Kernel: $KERNEL_VER (arm32)"
echo "  Image:  ${IMG_SIZE_MB}MB"
echo "============================================"

mkdir -p "$WORK"/{sources,output,rootfs,mnt}

# ============================================
# STEP 1: Build 32-bit Kernel
# ============================================
echo ""
echo ">>> STEP 1: Building 32-bit kernel..."

KDIR="$WORK/sources/linux-arm32"
if [ ! -d "$KDIR" ]; then
    git clone --depth 1 --branch "$KERNEL_VER" \
        https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git "$KDIR"
fi
cd "$KDIR"

# Use multi_v7_defconfig as base
make ARCH=arm CROSS_COMPILE=$CROSS multi_v7_defconfig

# Add H6-specific options
cat >> .config << 'EOF'
CONFIG_ARCH_SUNXI=y
CONFIG_MACH_SUN50I=y
CONFIG_SUN50I_DE2_BUS=y
CONFIG_SUNXI_WATCHDOG=y
CONFIG_SERIAL_8250_DW=y
CONFIG_MMC_SUNXI=y
CONFIG_USB_EHCI_HCD_PLATFORM=y
CONFIG_USB_OHCI_HCD_PLATFORM=y
CONFIG_NET_VENDOR_STMICRO=y
CONFIG_STMMAC_ETH=y
CONFIG_DWMAC_SUN8I=y
CONFIG_PHY_SUN4I_USB=y
CONFIG_REGULATOR_AXP20X=y
CONFIG_MFD_AXP20X_I2C=y
CONFIG_INPUT_AXP20X_PEK=y
CONFIG_SND_SUN4I_CODEC=y
CONFIG_COMMON_CLK_SUNXI_NG=y
CONFIG_SUN50I_H6_CCU=y
CONFIG_SUN50I_H6_R_CCU=y
CONFIG_PINCTRL_SUN50I_H6=y
CONFIG_PINCTRL_SUN50I_H6_R=y
CONFIG_GPIO_SYSFS=y
CONFIG_DEVTMPFS=y
CONFIG_DEVTMPFS_MOUNT=y
EOF

make ARCH=arm CROSS_COMPILE=$CROSS olddefconfig
make ARCH=arm CROSS_COMPILE=$CROSS -j$(nproc) zImage dtbs modules

# Copy outputs
cp arch/arm/boot/zImage "$WORK/output/"
echo "Kernel build complete."
ls -la "$WORK/output/zImage"

# Try to find or create H6 DTB
echo "Looking for H6 DTB..."
find arch/arm/boot/dts -name "*h6*" -o -name "*orangepi*3*" 2>/dev/null | head -5 || true

# If no H6 DTB was built (expected since H6 is arm64-only in mainline),
# copy the arm64 one and hope the kernel can parse it
if [ -f arch/arm64/boot/dts/allwinner/sun50i-h6-orangepi-3.dtb ]; then
    echo "Using arm64 DTB (may work with 32-bit kernel)"
    cp arch/arm64/boot/dts/allwinner/sun50i-h6-orangepi-3.dtb "$WORK/output/"
elif [ -f /build/output/sun50i-h6-orangepi-3.dtb ]; then
    echo "Using pre-built DTB from previous run"
else
    echo "WARNING: No H6 DTB found. Will need to build separately."
fi

# ============================================
# STEP 2: Create Devuan rootfs
# ============================================
echo ""
echo ">>> STEP 2: Creating Devuan Daedalus rootfs..."

ROOTFS="$WORK/rootfs"
rm -rf "$ROOTFS"/*

# Since we're on ARM64, we can run armhf binaries natively
# First check if we have armhf support
dpkg --print-architecture
dpkg --print-foreign-architectures || true

# Add armhf architecture support
dpkg --add-architecture armhf 2>/dev/null || true
apt-get update

# Run debootstrap for armhf
debootstrap --arch=armhf --include=locales,dialog,apt,openssh-server,htop,nano,wget,ca-certificates,net-tools,iproute2,isc-dhcp-client,eudev,kmod,procps,sysvinit-core,ifupdown \
    daedalus "$ROOTFS" http://deb.devuan.org/merged/

echo "Rootfs created successfully!"
du -sh "$ROOTFS"

# ============================================
# STEP 3: Configure rootfs
# ============================================
echo ""
echo ">>> STEP 3: Configuring rootfs..."

# Set hostname
echo "orangepi3" > "$ROOTFS/etc/hostname"

# Set root password to 'orangepi'
echo "root:orangepi" | chroot "$ROOTFS" chpasswd

# Enable serial console
cat > "$ROOTFS/etc/inittab.serial" << 'EOF'
T0:23:respawn:/sbin/getty -L ttyS0 115200 vt100
EOF
cat "$ROOTFS/etc/inittab.serial" >> "$ROOTFS/etc/inittab"

# Create fstab
cat > "$ROOTFS/etc/fstab" << 'EOF'
# /etc/fstab: static file system information.
/dev/mmcblk1p1  /       ext4    defaults,noatime        0       1
tmpfs           /tmp    tmpfs   defaults                0       0
EOF

# Network config
cat > "$ROOTFS/etc/network/interfaces" << 'EOF'
auto lo
iface lo inet loopback

auto eth0
iface eth0 inet dhcp
EOF

# Enable SSH root login
sed -i 's/#PermitRootLogin.*/PermitRootLogin yes/' "$ROOTFS/etc/ssh/sshd_config"
echo "PermitRootLogin yes" >> "$ROOTFS/etc/ssh/sshd_config"

# Install kernel modules
if [ -d "$KDIR" ]; then
    cd "$KDIR"
    make ARCH=arm CROSS_COMPILE=$CROSS INSTALL_MOD_PATH="$ROOTFS" modules_install
fi

# Copy kernel and DTB to boot
mkdir -p "$ROOTFS/boot"
cp "$WORK/output/zImage" "$ROOTFS/boot/"
cp "$WORK/output/"*.dtb "$ROOTFS/boot/" 2>/dev/null || true

# Create boot.scr source
cat > "$ROOTFS/boot/boot.cmd" << 'EOF'
setenv bootargs console=ttyS0,115200 root=/dev/mmcblk1p1 rootwait rw panic=10
load mmc 1:1 0x42000000 /boot/zImage
load mmc 1:1 0x44000000 /boot/sun50i-h6-orangepi-3.dtb
bootz 0x42000000 - 0x44000000
EOF

# Build boot.scr
mkimage -C none -A arm -T script -d "$ROOTFS/boot/boot.cmd" "$ROOTFS/boot/boot.scr"

echo "Rootfs configuration complete."

# ============================================
# STEP 4: Assemble SD card image
# ============================================
echo ""
echo ">>> STEP 4: Assembling SD card image..."

# Create empty image
dd if=/dev/zero of="$IMG" bs=1M count=$IMG_SIZE_MB status=progress

# Create partition table
parted -s "$IMG" mklabel msdos
parted -s "$IMG" mkpart primary ext4 1MiB 100%

# Setup loop device
LOOP=$(losetup --show -fP "$IMG")
echo "Loop device: $LOOP"

# Format partition
mkfs.ext4 -F "${LOOP}p1"

# Mount and copy rootfs
mkdir -p /mnt/sd
mount "${LOOP}p1" /mnt/sd
cp -a "$ROOTFS/"* /mnt/sd/
sync

# Unmount
umount /mnt/sd

# Write bootloader at 8KB offset
if [ -f /build/output/u-boot-sunxi-with-spl-arm32.bin ]; then
    dd if=/build/output/u-boot-sunxi-with-spl-arm32.bin of="$LOOP" bs=1024 seek=8 conv=notrunc
    echo "Bootloader written to image."
else
    echo "WARNING: Bootloader not found at /build/output/u-boot-sunxi-with-spl-arm32.bin"
    echo "You will need to flash it separately."
fi

# Cleanup
losetup -d "$LOOP"

echo ""
echo "============================================"
echo "  BUILD COMPLETE!"
echo "============================================"
echo "  Image: $IMG"
ls -lh "$IMG"
echo ""
echo "  Flash to SD card with:"
echo "    sudo dd if=$IMG of=/dev/sdX bs=4M status=progress"
echo "============================================"
