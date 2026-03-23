#!/bin/bash
# Build U-Boot for Orange Pi 3 LTS (Allwinner H6)
set -euo pipefail

WORK="${WORK:-$HOME/opi3-build}"
UBOOT_VERSION="${UBOOT_VERSION:-v2024.01}"
UBOOT_DIR="$WORK/sources/uboot"

# BL31 must be set
if [ -z "${BL31:-}" ]; then
    BL31="$WORK/sources/tfa/build/sun50i_h6/release/bl31.bin"
fi
if [ ! -f "$BL31" ]; then
    echo "ERROR: BL31 not found at $BL31"
    echo "Build TF-A first: ./scripts/build-tfa.sh"
    exit 1
fi
export BL31

echo "=== Building U-Boot $UBOOT_VERSION ==="
echo "BL31: $BL31"

mkdir -p "$WORK/sources" "$WORK/output"

if [ ! -d "$UBOOT_DIR" ]; then
    echo "Cloning U-Boot..."
    git clone --depth 1 --branch "$UBOOT_VERSION" \
        https://source.denx.de/u-boot/u-boot.git "$UBOOT_DIR"
else
    echo "U-Boot source already present at $UBOOT_DIR"
fi

cd "$UBOOT_DIR"

# Detect correct defconfig: prefer LTS variant
if [ -f configs/orangepi_3_lts_defconfig ]; then
    DEFCONFIG=orangepi_3_lts_defconfig
else
    DEFCONFIG=orangepi_3_defconfig
    echo "NOTE: LTS defconfig not found, using $DEFCONFIG"
fi

echo "Using defconfig: $DEFCONFIG"

make CROSS_COMPILE=aarch64-linux-gnu- "$DEFCONFIG"
make CROSS_COMPILE=aarch64-linux-gnu- -j"$(nproc)"

if [ ! -f u-boot-sunxi-with-spl.bin ]; then
    echo "ERROR: u-boot-sunxi-with-spl.bin not produced"
    exit 1
fi

cp u-boot-sunxi-with-spl.bin "$WORK/output/"

echo "=== U-Boot build complete ==="
echo "Output: $WORK/output/u-boot-sunxi-with-spl.bin"
