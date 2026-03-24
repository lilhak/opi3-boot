#!/bin/bash
# Build 32-bit (AArch32) Linux kernel for Orange Pi 3 LTS (Allwinner H6)
#
# This builds an armhf kernel (zImage) by porting the H6 device tree
# from arch/arm64 to arch/arm and enabling H6 drivers in the 32-bit build.
#
# The Cortex-A53 supports AArch32 at all exception levels including EL1
# (kernel mode), so this is architecturally valid.
set -euo pipefail

WORK="${WORK:-$HOME/opi3-build}"
KERNEL_VERSION="${KERNEL_VERSION:-v6.6.70}"
KERNEL_DIR="$WORK/sources/linux-arm32"
CROSS="${CROSS_COMPILE:-arm-linux-gnueabihf-}"

echo "=== Building 32-bit Linux kernel $KERNEL_VERSION for H6 ==="
echo "Cross compiler: ${CROSS}"

mkdir -p "$WORK/sources" "$WORK/output"

# --- Clone kernel ---
if [ ! -d "$KERNEL_DIR" ]; then
    echo "Cloning kernel (shallow)..."
    git clone --depth 1 --branch "$KERNEL_VERSION" \
        https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git "$KERNEL_DIR"
else
    echo "Kernel source already present at $KERNEL_DIR"
fi

cd "$KERNEL_DIR"

# --- Port H6 Device Tree from arm64 to arm ---
DTS_ARM_DIR="arch/arm/boot/dts/allwinner"
DTS_ARM64_DIR="arch/arm64/boot/dts/allwinner"
mkdir -p "$DTS_ARM_DIR"

# Copy the DTSI and DTS files
echo "Porting H6 device tree to arch/arm..."

# Copy the base DTSI (shared definitions)
if [ -f "$DTS_ARM64_DIR/sun50i-h6.dtsi" ]; then
    cp "$DTS_ARM64_DIR/sun50i-h6.dtsi" "$DTS_ARM_DIR/"

    # Patch the timer compatible: armv8-timer -> armv7-timer
    # (same hardware, different compatible string for 32-bit kernel)
    sed -i 's/arm,armv8-timer/arm,armv7-timer/g' "$DTS_ARM_DIR/sun50i-h6.dtsi"

    echo "  Copied and patched sun50i-h6.dtsi"
else
    echo "ERROR: sun50i-h6.dtsi not found in $DTS_ARM64_DIR"
    exit 1
fi

# Copy board DTS
for dts in sun50i-h6-orangepi-3.dts sun50i-h6-orangepi-3-lts.dts; do
    if [ -f "$DTS_ARM64_DIR/$dts" ]; then
        cp "$DTS_ARM64_DIR/$dts" "$DTS_ARM_DIR/"
        echo "  Copied $dts"
    fi
done

# Copy any other DTSI files that sun50i-h6.dtsi includes
for dtsi in sun50i-h6-cpu-opp.dtsi sun50i-h6-gpu-opp.dtsi; do
    if [ -f "$DTS_ARM64_DIR/$dtsi" ]; then
        cp "$DTS_ARM64_DIR/$dtsi" "$DTS_ARM_DIR/"
        echo "  Copied $dtsi"
    fi
done

# Copy shared sunxi DTSI files that may be referenced
for dtsi in sunxi-h6-gpio.dtsi; do
    if [ -f "$DTS_ARM64_DIR/$dtsi" ]; then
        cp "$DTS_ARM64_DIR/$dtsi" "$DTS_ARM_DIR/"
        echo "  Copied $dtsi"
    fi
done

# Add H6 DTS to the arm Makefile
DTS_MAKEFILE="$DTS_ARM_DIR/Makefile"
if [ -f "$DTS_MAKEFILE" ]; then
    if ! grep -q "sun50i-h6-orangepi-3" "$DTS_MAKEFILE"; then
        echo 'dtb-$(CONFIG_MACH_SUN50I) += sun50i-h6-orangepi-3.dtb' >> "$DTS_MAKEFILE"
        if [ -f "$DTS_ARM_DIR/sun50i-h6-orangepi-3-lts.dts" ]; then
            echo 'dtb-$(CONFIG_MACH_SUN50I) += sun50i-h6-orangepi-3-lts.dtb' >> "$DTS_MAKEFILE"
        fi
        echo "  Added H6 DTBs to Makefile"
    fi
else
    # Create Makefile if it doesn't exist
    cat > "$DTS_MAKEFILE" << 'MAKEFILE'
# SPDX-License-Identifier: GPL-2.0
dtb-$(CONFIG_MACH_SUN50I) += sun50i-h6-orangepi-3.dtb
MAKEFILE
    if [ -f "$DTS_ARM_DIR/sun50i-h6-orangepi-3-lts.dts" ]; then
        echo 'dtb-$(CONFIG_MACH_SUN50I) += sun50i-h6-orangepi-3-lts.dtb' >> "$DTS_MAKEFILE"
    fi
    echo "  Created DTS Makefile"
fi

# --- Add H6 compatible string to mach-sunxi ---
SUNXI_C="arch/arm/mach-sunxi/sunxi.c"
if [ -f "$SUNXI_C" ]; then
    if ! grep -q "sun50i-h6" "$SUNXI_C"; then
        echo "Adding H6 compatible string to mach-sunxi..."
        # Add "allwinner,sun50i-h6" to the DT machine compatible list
        sed -i '/static const char \* const sunxi_dt_compat\[\]/,/};/{
            /NULL/i\
\t"allwinner,sun50i-h6",
        }' "$SUNXI_C"
        echo "  Added allwinner,sun50i-h6 to sunxi_dt_compat[]"
    fi
fi

# --- Add MACH_SUN50I to Kconfig if not present ---
KCONFIG="arch/arm/mach-sunxi/Kconfig"
if [ -f "$KCONFIG" ]; then
    if ! grep -q "MACH_SUN50I" "$KCONFIG"; then
        echo "Adding MACH_SUN50I to Kconfig..."
        # Add it after the last MACH_SUN8I entry
        sed -i '/config MACH_SUN9I/i\
config MACH_SUN50I\
\tbool "Allwinner sun50i (A64/H5/H6) family - 32-bit mode"\
\tdefault y\
\tdepends on ARCH_SUNXI\
\tselect ARM_GIC\
\tselect ARM_PSCI\
\tselect PINCTRL_SUN50I_H6\
\n' "$KCONFIG"
        echo "  Added MACH_SUN50I config"
    fi
fi

# --- Add Cortex-A53 CPU ID to proc-v7.S ---
# The Cortex-A53 (MIDR 0x410fd03x) runs AArch32 at all exception levels
# but has no proc_info entry in the 32-bit ARM kernel. Without this, the
# kernel falls through to the generic v7 fallback which doesn't properly
# initialize SMP for the core.
PROC_V7="arch/arm/mm/proc-v7.S"
if [ -f "$PROC_V7" ]; then
    if ! grep -q "ca53mp" "$PROC_V7"; then
        echo "Adding Cortex-A53 CPU ID to proc-v7.S..."

        # 1. Add setup label: __v7_ca53mp_setup alongside the A7/A12/A15/A17 group
        #    (these cores use mov r10, #0 - no explicit broadcasting needed)
        sed -i '/__v7_ca17mp_setup:/a\
__v7_ca53mp_setup:' "$PROC_V7"

        # 2. Add proc_info entry after __v7_ca17mp_proc_info block
        #    MIDR 0x410fd030, mask 0xff0ffff0 (matches Cortex-A53 rXpY)
        sed -i '/\.size\t__v7_ca17mp_proc_info/a\
\
\t/*\
\t * ARM Ltd. Cortex A53 processor (AArch32 mode).\
\t * MIDR: 0x410fd03x\
\t */\
\t.type\t__v7_ca53mp_proc_info, #object\
__v7_ca53mp_proc_info:\
\t.long\t0x410fd030\
\t.long\t0xff0ffff0\
\t__v7_proc __v7_ca53mp_proc_info, __v7_ca53mp_setup, proc_fns = HARDENED_BPIALL_PROCESSOR_FUNCTIONS\
\t.size\t__v7_ca53mp_proc_info, . - __v7_ca53mp_proc_info' "$PROC_V7"

        echo "  Added Cortex-A53 (0x410fd03x) proc_info entry"
    else
        echo "  Cortex-A53 CPU ID already present in proc-v7.S"
    fi
else
    echo "WARNING: proc-v7.S not found at $PROC_V7"
fi

# --- Configure kernel ---
echo "Configuring kernel..."

# Start with multi_v7_defconfig (broad sunxi support)
make ARCH=arm CROSS_COMPILE="$CROSS" multi_v7_defconfig

# Enable H6-specific options
echo "Applying H6 config overrides..."
./scripts/config --enable CONFIG_ARCH_SUNXI
./scripts/config --enable CONFIG_MACH_SUN50I
./scripts/config --enable CONFIG_SMP
./scripts/config --set-val CONFIG_NR_CPUS 4

# Clock controller (H6-specific, but driver is architecture-neutral)
./scripts/config --enable CONFIG_SUN50I_H6_CCU

# Pin controller
./scripts/config --enable CONFIG_PINCTRL_SUN50I_H6

# MMC (SD card boot)
./scripts/config --enable CONFIG_MMC
./scripts/config --enable CONFIG_MMC_SUNXI

# Filesystem
./scripts/config --enable CONFIG_EXT4_FS
./scripts/config --enable CONFIG_TMPFS

# Serial console (DesignWare 8250 UART)
./scripts/config --enable CONFIG_SERIAL_8250
./scripts/config --enable CONFIG_SERIAL_8250_OF
./scripts/config --enable CONFIG_SERIAL_8250_DW
./scripts/config --enable CONFIG_SERIAL_8250_CONSOLE
./scripts/config --enable CONFIG_SERIAL_EARLYCON

# Device hotplug
./scripts/config --enable CONFIG_DEVTMPFS
./scripts/config --enable CONFIG_DEVTMPFS_MOUNT

# USB
./scripts/config --enable CONFIG_USB_EHCI_HCD
./scripts/config --enable CONFIG_USB_OHCI_HCD
./scripts/config --enable CONFIG_USB_STORAGE
./scripts/config --enable CONFIG_PHY_SUN50I_USB3

# Ethernet
./scripts/config --enable CONFIG_DWMAC_SUN8I
./scripts/config --enable CONFIG_STMMAC_ETH

# PMIC (AXP805/AXP806 via RSB)
./scripts/config --enable CONFIG_SUNXI_RSB
./scripts/config --enable CONFIG_MFD_AXP20X_RSB
./scripts/config --enable CONFIG_REGULATOR_AXP20X
./scripts/config --enable CONFIG_INPUT_AXP20X_PEK

# Thermal
./scripts/config --enable CONFIG_SUN50I_H6_THS

# GIC interrupt controller
./scripts/config --enable CONFIG_ARM_GIC

# Resolve dependencies
make ARCH=arm CROSS_COMPILE="$CROSS" olddefconfig

# --- Build ---
echo "Building kernel, DTBs, and modules..."
make ARCH=arm CROSS_COMPILE="$CROSS" -j"$(nproc)" zImage dtbs modules

# --- Copy outputs ---
cp arch/arm/boot/zImage "$WORK/output/"

# Determine correct DTB
DTB_DIR="arch/arm/boot/dts/allwinner"
if [ -f "$DTB_DIR/sun50i-h6-orangepi-3-lts.dtb" ]; then
    DTB_NAME=sun50i-h6-orangepi-3-lts.dtb
elif [ -f "$DTB_DIR/sun50i-h6-orangepi-3.dtb" ]; then
    DTB_NAME=sun50i-h6-orangepi-3.dtb
else
    echo "WARNING: H6 DTB not built. Checking if DTS compile had issues..."
    echo "Try: make ARCH=arm CROSS_COMPILE=$CROSS allwinner/sun50i-h6-orangepi-3.dtb"
    # Attempt to build just the DTB for diagnostics
    make ARCH=arm CROSS_COMPILE="$CROSS" "allwinner/sun50i-h6-orangepi-3.dtb" || true
    if [ -f "$DTB_DIR/sun50i-h6-orangepi-3.dtb" ]; then
        DTB_NAME=sun50i-h6-orangepi-3.dtb
    else
        echo "ERROR: Cannot build H6 DTB. Manual DTS porting may be needed."
        echo "Check $DTS_ARM_DIR/sun50i-h6.dtsi for compile errors."
        exit 1
    fi
fi

cp "$DTB_DIR/$DTB_NAME" "$WORK/output/"
echo "$DTB_NAME" > "$WORK/output/dtb-name.txt"

echo ""
echo "=== 32-bit kernel build complete ==="
echo "zImage: $WORK/output/zImage"
echo "DTB:    $WORK/output/$DTB_NAME"
echo ""
echo "Verify it's 32-bit:"
file arch/arm/boot/zImage
echo ""
echo "Install modules into rootfs with:"
echo "  cd $KERNEL_DIR"
echo "  sudo make ARCH=arm CROSS_COMPILE=$CROSS INSTALL_MOD_PATH=\$WORK/rootfs modules_install"
echo ""
echo "NOTE: This kernel boots SINGLE CORE by default (no TF-A = no PSCI for SMP)."
echo "See docs/h6-32bit-research.md section 3.4 for SMP options."
