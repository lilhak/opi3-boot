#!/bin/bash
# Build arm64 Linux kernel for Orange Pi 3 LTS
set -euo pipefail

WORK="${WORK:-$HOME/opi3-build}"
KERNEL_VERSION="${KERNEL_VERSION:-v6.6.70}"
KERNEL_DIR="$WORK/sources/linux"

echo "=== Building Linux kernel $KERNEL_VERSION (arm64) ==="

mkdir -p "$WORK/sources" "$WORK/output"

if [ ! -d "$KERNEL_DIR" ]; then
    echo "Cloning kernel (shallow)..."
    git clone --depth 1 --branch "$KERNEL_VERSION" \
        https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git "$KERNEL_DIR"
else
    echo "Kernel source already present at $KERNEL_DIR"
fi

cd "$KERNEL_DIR"

# Generate defconfig
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- defconfig

# Apply critical config overrides
echo "Applying config overrides..."
./scripts/config --enable CONFIG_COMPAT
./scripts/config --enable CONFIG_SMP
./scripts/config --enable CONFIG_ARCH_SUNXI
./scripts/config --enable CONFIG_SUN50I_H6_CCU
./scripts/config --enable CONFIG_DWMAC_SUN8I
./scripts/config --enable CONFIG_STMMAC_ETH
./scripts/config --enable CONFIG_PHY_SUN50I_USB3
./scripts/config --enable CONFIG_SERIAL_8250
./scripts/config --enable CONFIG_SERIAL_8250_DW
./scripts/config --enable CONFIG_SERIAL_8250_CONSOLE
./scripts/config --enable CONFIG_USB_EHCI_HCD
./scripts/config --enable CONFIG_USB_OHCI_HCD
./scripts/config --enable CONFIG_USB_STORAGE
./scripts/config --enable CONFIG_MMC
./scripts/config --enable CONFIG_MMC_SUNXI
./scripts/config --enable CONFIG_EXT4_FS
./scripts/config --enable CONFIG_TMPFS
./scripts/config --enable CONFIG_DEVTMPFS
./scripts/config --enable CONFIG_DEVTMPFS_MOUNT
./scripts/config --enable CONFIG_SUNXI_RSB
./scripts/config --enable CONFIG_MFD_AXP20X_RSB
./scripts/config --enable CONFIG_REGULATOR_AXP20X
./scripts/config --enable CONFIG_INPUT_AXP20X_PEK
./scripts/config --enable CONFIG_SUN50I_H6_THS

# Resolve any dependencies
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- olddefconfig

# Verify critical options
if ! grep -q "CONFIG_COMPAT=y" .config; then
    echo "ERROR: CONFIG_COMPAT not enabled -- armhf binaries will not run!"
    exit 1
fi

# Build
echo "Building kernel, DTBs, and modules..."
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- -j"$(nproc)" Image dtbs modules

# Copy outputs
cp arch/arm64/boot/Image "$WORK/output/"

# Determine correct DTB
if [ -f arch/arm64/boot/dts/allwinner/sun50i-h6-orangepi-3-lts.dtb ]; then
    DTB_NAME=sun50i-h6-orangepi-3-lts.dtb
else
    DTB_NAME=sun50i-h6-orangepi-3.dtb
    echo "WARNING: LTS DTB not found, using non-LTS DTB ($DTB_NAME)"
    echo "Ethernet may not work -- see BUILD-GUIDE.md section 12 / Appendix B"
fi

cp "arch/arm64/boot/dts/allwinner/$DTB_NAME" "$WORK/output/"

# Save DTB name for other scripts
echo "$DTB_NAME" > "$WORK/output/dtb-name.txt"

echo "=== Kernel build complete ==="
echo "Image: $WORK/output/Image"
echo "DTB:   $WORK/output/$DTB_NAME"
echo ""
echo "Install modules into rootfs with:"
echo "  cd $KERNEL_DIR"
echo "  sudo make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- INSTALL_MOD_PATH=\$WORK/rootfs modules_install"
