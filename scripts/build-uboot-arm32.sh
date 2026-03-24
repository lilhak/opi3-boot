#!/bin/bash
# Build 32-bit (AArch32) U-Boot for Orange Pi 3 LTS (Allwinner H6)
#
# This builds a fully 32-bit U-Boot (SPL + proper) by patching the
# mainline U-Boot Kconfig to allow ARM32 builds for the H6 SoC.
# No TF-A needed. No RMR switch. The system stays in AArch32 natively.
#
# Based on Andre Przywara's unmerged FEL 32-bit patches (2019).
set -euo pipefail

WORK="${WORK:-$HOME/opi3-build}"
UBOOT_VERSION="${UBOOT_VERSION:-v2024.01}"
UBOOT_DIR="$WORK/sources/uboot-arm32"
CROSS="${CROSS_COMPILE:-arm-linux-gnueabihf-}"

echo "=== Building 32-bit U-Boot $UBOOT_VERSION for H6 ==="
echo "Cross compiler: ${CROSS}"

mkdir -p "$WORK/sources" "$WORK/output"

# --- Clone U-Boot ---
if [ ! -d "$UBOOT_DIR" ]; then
    echo "Cloning U-Boot..."
    git clone --depth 1 --branch "$UBOOT_VERSION" \
        https://source.denx.de/u-boot/u-boot.git "$UBOOT_DIR"
else
    echo "U-Boot source already present at $UBOOT_DIR"
fi

cd "$UBOOT_DIR"

# --- Apply Kconfig patch for 32-bit ARMv8 builds ---
# This patch allows MACH_SUN50I_H6 to be built with ARCH=arm instead of
# ARCH=arm64 by adding a CONFIG_SUNXI_ARMV8_32BIT_BUILD option.
if ! grep -q "SUNXI_ARMV8_32BIT_BUILD" arch/arm/mach-sunxi/Kconfig 2>/dev/null; then
    echo "Applying 32-bit ARMv8 Kconfig patch..."
    cat > /tmp/sunxi-arm32.patch << 'PATCH'
--- a/arch/arm/mach-sunxi/Kconfig
+++ b/arch/arm/mach-sunxi/Kconfig
@@ -3,6 +3,19 @@

 if ARCH_SUNXI

+config SUNXI_ARMV8_32BIT_BUILD
+	bool "Build a 32-bit (AArch32) binary for ARMv8 SoC"
+	depends on MACH_SUN50I || MACH_SUN50I_H5 || MACH_SUN50I_H6
+	help
+	  Build a 32-bit ARM binary instead of 64-bit. This produces
+	  a U-Boot that stays in AArch32 mode and never triggers the
+	  RMR switch to AArch64.
+
+	  The resulting SPL initializes DRAM in AArch32 and loads a
+	  32-bit U-Boot proper. No TF-A/BL31 is needed.
+
+	  Say Y if you want a fully 32-bit boot chain.
+
 config SPL_LDSCRIPT
 	default "arch/arm/cpu/armv7/sunxi/u-boot-spl.lds" if !ARM64

PATCH

    # Apply the patch (may need manual adjustment depending on U-Boot version)
    # Instead of patch, do it via sed for reliability across versions
    if grep -q "^if ARCH_SUNXI" arch/arm/mach-sunxi/Kconfig; then
        sed -i '/^if ARCH_SUNXI/a\
\
config SUNXI_ARMV8_32BIT_BUILD\
\tbool "Build a 32-bit (AArch32) binary for ARMv8 SoC"\
\tdepends on MACH_SUN50I || MACH_SUN50I_H5 || MACH_SUN50I_H6\
\thelp\
\t  Build a 32-bit ARM binary instead of 64-bit. This produces\
\t  a U-Boot that stays in AArch32 mode and never triggers the\
\t  RMR switch to AArch64. No TF-A needed.\
' arch/arm/mach-sunxi/Kconfig
    fi

    # Modify MACH_SUN50I_H6 to conditionally select ARM64 vs CPU_V7A
    sed -i '/config MACH_SUN50I_H6/{
        n
        /bool/n
        s/select ARM64/select ARM64 if !SUNXI_ARMV8_32BIT_BUILD\
\tselect CPU_V7A if SUNXI_ARMV8_32BIT_BUILD/
    }' arch/arm/mach-sunxi/Kconfig

    # Ensure SUN50I_GEN_H6 doesn't force FIT when doing 32-bit build
    # (32-bit U-Boot uses legacy image format, not FIT)
    sed -i '/config SUN50I_GEN_H6/{
        n
        /bool/n
        s/select FIT/select FIT if !SUNXI_ARMV8_32BIT_BUILD/
        n
        s/select SPL_LOAD_FIT if SPL/select SPL_LOAD_FIT if SPL \&\& !SUNXI_ARMV8_32BIT_BUILD/
    }' arch/arm/mach-sunxi/Kconfig

    echo "Kconfig patch applied."
else
    echo "Kconfig already patched for 32-bit build."
fi

# --- Create custom defconfig ---
DEFCONFIG_NAME="orangepi_3_arm32_defconfig"
cat > "configs/$DEFCONFIG_NAME" << 'DEFCONFIG'
CONFIG_ARM=y
CONFIG_ARCH_SUNXI=y
CONFIG_SPL=y
CONFIG_MACH_SUN50I_H6=y
CONFIG_SUNXI_ARMV8_32BIT_BUILD=y
CONFIG_DRAM_SUN50I_H6=y
CONFIG_SUNXI_DRAM_H6_LPDDR3=y
CONFIG_DRAM_CLK=744
CONFIG_DRAM_ZQ=3881979
CONFIG_DRAM_ODT_EN=y
CONFIG_MMC_SUNXI_SLOT_EXTRA=2
CONFIG_NR_DRAM_BANKS=1
CONFIG_DEFAULT_DEVICE_TREE="sun50i-h6-orangepi-3"
# Boot configuration
CONFIG_BOOTDELAY=3
CONFIG_AUTOBOOT=y
CONFIG_USE_BOOTCOMMAND=y
CONFIG_BOOTCOMMAND="if load mmc 0:1 0x42000000 /boot/boot.scr; then source 0x42000000; else load mmc 1:1 0x42000000 /boot/boot.scr; source 0x42000000; fi"
# MMC support
CONFIG_MMC=y
CONFIG_MMC_SUNXI=y
# Filesystem support
CONFIG_FS_EXT4=y
CONFIG_CMD_EXT4=y
CONFIG_CMD_FAT=y
CONFIG_CMD_FS_GENERIC=y
# Console
CONFIG_CONS_INDEX=1
CONFIG_SYS_NS16550=y
# Disable features not needed in 32-bit mode
# CONFIG_ARM64 is not set
# CONFIG_SYS_MALLOC_CLEAR_ON_INIT is not set
# CONFIG_CMD_FLASH is not set
# CONFIG_SPL_DOS_PARTITION is not set
# CONFIG_SPL_EFI_PARTITION is not set
DEFCONFIG

echo "Created $DEFCONFIG_NAME"

# --- Build ---
echo "Configuring..."
make ARCH=arm CROSS_COMPILE="$CROSS" "$DEFCONFIG_NAME"

echo "Building (ARCH=arm, no TF-A, no RMR switch)..."
make ARCH=arm CROSS_COMPILE="$CROSS" -j"$(nproc)"

# --- Verify output ---
# The combined image should be produced
if [ -f u-boot-sunxi-with-spl.bin ]; then
    cp u-boot-sunxi-with-spl.bin "$WORK/output/u-boot-sunxi-with-spl-arm32.bin"
    echo ""
    echo "=== U-Boot 32-bit build complete ==="
    echo "Output: $WORK/output/u-boot-sunxi-with-spl-arm32.bin"
    echo ""
    echo "Verify it's 32-bit:"
    file spl/u-boot-spl
    echo ""
    ls -la "$WORK/output/u-boot-sunxi-with-spl-arm32.bin"
elif [ -f spl/sunxi-spl.bin ] && [ -f u-boot.bin ]; then
    # If combined image wasn't produced, concatenate manually
    echo "Combined image not produced, concatenating SPL + U-Boot..."
    # SPL goes at offset 0 (with eGON header), U-Boot at a safe offset
    # The SPL has the eGON header and will be written at 8KB on SD card
    cp spl/sunxi-spl.bin "$WORK/output/sunxi-spl-arm32.bin"
    cp u-boot.bin "$WORK/output/u-boot-arm32.bin"

    # Create combined image: SPL at 0, pad to 32KB, then U-Boot
    dd if=/dev/zero of="$WORK/output/u-boot-sunxi-with-spl-arm32.bin" bs=1k count=1024
    dd if=spl/sunxi-spl.bin of="$WORK/output/u-boot-sunxi-with-spl-arm32.bin" conv=notrunc
    dd if=u-boot.bin of="$WORK/output/u-boot-sunxi-with-spl-arm32.bin" bs=1k seek=32 conv=notrunc

    echo ""
    echo "=== U-Boot 32-bit build complete (manual concat) ==="
    echo "SPL:     $WORK/output/sunxi-spl-arm32.bin"
    echo "U-Boot:  $WORK/output/u-boot-arm32.bin"
    echo "Combined: $WORK/output/u-boot-sunxi-with-spl-arm32.bin"
else
    echo "ERROR: No U-Boot binary produced!"
    echo "Check build output above for errors."
    echo ""
    echo "Common issues:"
    echo "  - Kconfig patch didn't apply correctly"
    echo "  - Missing cross-compiler: apt install gcc-arm-linux-gnueabihf"
    echo "  - CONFIG conflicts: run 'make ARCH=arm menuconfig' to debug"
    exit 1
fi
