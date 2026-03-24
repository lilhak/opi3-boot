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
CONFIG_SERIAL_8250_OF=y
CONFIG_SERIAL_8250_CONSOLE=y
CONFIG_SERIAL_EARLYCON=y
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
# --- Low-level debug: H6 UART0 at 0x05000000 (DesignWare 8250) ---
CONFIG_DEBUG_LL=y
CONFIG_DEBUG_UART_8250=y
CONFIG_DEBUG_UART_8250_SHIFT=2
CONFIG_DEBUG_UART_PHYS=0x05000000
CONFIG_DEBUG_UART_VIRT=0xf5000000
CONFIG_DEBUG_LL_INCLUDE="debug/8250.S"
CONFIG_EARLY_PRINTK=y
EOF

make ARCH=arm CROSS_COMPILE=$CROSS olddefconfig

# --- Patch: Add Cortex-A53 CPU ID to proc-v7.S ---
# The Cortex-A53 (MIDR 0x410fd03x) runs AArch32 at all exception levels
# but has no proc_info entry in the 32-bit ARM kernel. Without this, the
# kernel falls through to the generic v7 fallback which doesn't initialize
# SMP properly for the core.
PROC_V7="arch/arm/mm/proc-v7.S"
if [ -f "$PROC_V7" ] && ! grep -q "ca53mp" "$PROC_V7"; then
    echo "Patching proc-v7.S: Adding Cortex-A53 CPU ID..."

    # 1. Add setup label alongside the A7/A12/A15/A17 group
    #    (these use mov r10, #0 - broadcasting is implicit for v8 cores)
    sed -i '/__v7_ca17mp_setup:/a\
__v7_ca53mp_setup:' "$PROC_V7"

    # 2. Add proc_info entry after the A17 block
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

    echo "  Added Cortex-A53 (0x410fd03x) proc_info entry to proc-v7.S"
else
    echo "  Cortex-A53 CPU ID already present or proc-v7.S not found"
fi

# --- Patch: Add H6 SMP support to platsmp.c ---
PLATSMP="arch/arm/mach-sunxi/platsmp.c"
if [ -f "$PLATSMP" ] && ! grep -q "sun50i_h6_smp" "$PLATSMP"; then
    echo "Adding H6 SMP support to platsmp.c..."
    cat >> "$PLATSMP" << 'H6SMP'

/*
 * H6 (sun50i) SMP support for AArch32 mode
 *
 * The H6 is a 64-bit capable SoC but can run entirely in 32-bit mode.
 * This requires:
 * 1. Setting AA64nAA32 bit to 0 (32-bit mode) for each CPU
 * 2. Using RVBAR registers for the entry point (32-bit physical address)
 * 3. Different power sequencing than older sunxi SoCs
 *
 * Register bases (from TF-A sun50i_h6):
 * - CPUCFG: 0x09010000
 * - R_CPUCFG: 0x07000400
 */

/* H6 CPUCFG registers */
#define H6_CPUCFG_BASE                  0x09010000
#define H6_R_CPUCFG_BASE                0x07000400

#define H6_CPUCFG_RST_CTRL_REG(c)       (0x0000 + (c) * 4)
#define H6_CPUCFG_CLS_CTRL_REG0(c)      (0x0010 + (c) * 0x10)
#define H6_CPUCFG_RVBAR_LO_REG(n)       (0x0040 + (n) * 8)
#define H6_CPUCFG_RVBAR_HI_REG(n)       (0x0044 + (n) * 8)
#define H6_CPUCFG_DBG_REG0              0x00c0

#define H6_POWERON_RST_REG(c)           (0x0040 + (c) * 4)
#define H6_POWEROFF_GATING_REG(c)       (0x0044 + (c) * 4)
#define H6_CPU_POWER_CLAMP_REG(c, n)    (0x0050 + (c) * 0x10 + (n) * 4)

#define H6_AA64nAA32_OFFSET             24

static void __iomem *h6_cpucfg_membase;
static void __iomem *h6_r_cpucfg_membase;

static void h6_cpu_power_clamp(unsigned int cpu, bool enable)
{
    if (enable) {
        /* Power enable sequence from Allwinner BSP / TF-A */
        writel(0xfe, h6_r_cpucfg_membase + H6_CPU_POWER_CLAMP_REG(0, cpu));
        writel(0xf8, h6_r_cpucfg_membase + H6_CPU_POWER_CLAMP_REG(0, cpu));
        writel(0xe0, h6_r_cpucfg_membase + H6_CPU_POWER_CLAMP_REG(0, cpu));
        writel(0x80, h6_r_cpucfg_membase + H6_CPU_POWER_CLAMP_REG(0, cpu));
        writel(0x00, h6_r_cpucfg_membase + H6_CPU_POWER_CLAMP_REG(0, cpu));
        udelay(1);
    } else {
        writel(0xff, h6_r_cpucfg_membase + H6_CPU_POWER_CLAMP_REG(0, cpu));
    }
}

static void __init sun50i_h6_smp_prepare_cpus(unsigned int max_cpus)
{
    h6_cpucfg_membase = ioremap(H6_CPUCFG_BASE, 0x200);
    if (!h6_cpucfg_membase) {
        pr_err("H6 SMP: Couldn't map CPUCFG registers\n");
        return;
    }

    h6_r_cpucfg_membase = ioremap(H6_R_CPUCFG_BASE, 0x200);
    if (!h6_r_cpucfg_membase) {
        pr_err("H6 SMP: Couldn't map R_CPUCFG registers\n");
        iounmap(h6_cpucfg_membase);
        h6_cpucfg_membase = NULL;
        return;
    }

    pr_info("H6 SMP: CPUCFG at %p, R_CPUCFG at %p\n",
            h6_cpucfg_membase, h6_r_cpucfg_membase);
}

static int sun50i_h6_smp_boot_secondary(unsigned int cpu,
                                        struct task_struct *idle)
{
    u32 reg;
    phys_addr_t entry = __pa_symbol(secondary_startup);

    if (!(h6_cpucfg_membase && h6_r_cpucfg_membase))
        return -EFAULT;

    pr_debug("H6 SMP: Booting CPU %d, entry point 0x%llx\n",
             cpu, (unsigned long long)entry);

    spin_lock(&cpu_lock);

    /* Step 1: Assert CPU core reset */
    reg = readl(h6_cpucfg_membase + H6_CPUCFG_RST_CTRL_REG(0));
    writel(reg & ~BIT(cpu), h6_cpucfg_membase + H6_CPUCFG_RST_CTRL_REG(0));

    /* Step 2: Assert CPU power-on reset */
    reg = readl(h6_r_cpucfg_membase + H6_POWERON_RST_REG(0));
    writel(reg & ~BIT(cpu), h6_r_cpucfg_membase + H6_POWERON_RST_REG(0));

    /* Step 3: Set CPU to start in AArch32 mode (clear AA64nAA32 bit) */
    reg = readl(h6_cpucfg_membase + H6_CPUCFG_CLS_CTRL_REG0(0));
    writel(reg & ~BIT(H6_AA64nAA32_OFFSET + cpu),
           h6_cpucfg_membase + H6_CPUCFG_CLS_CTRL_REG0(0));

    /* Step 4: Set the entry point via RVBAR (32-bit address, high bits 0) */
    writel(entry, h6_cpucfg_membase + H6_CPUCFG_RVBAR_LO_REG(cpu));
    writel(0, h6_cpucfg_membase + H6_CPUCFG_RVBAR_HI_REG(cpu));

    /* Ensure entry point is visible */
    dsb(sy);
    isb();

    /* Step 5: Apply power to the CPU */
    h6_cpu_power_clamp(cpu, true);

    /* Step 6: Release the core output clamps */
    reg = readl(h6_r_cpucfg_membase + H6_POWEROFF_GATING_REG(0));
    writel(reg & ~BIT(cpu), h6_r_cpucfg_membase + H6_POWEROFF_GATING_REG(0));
    udelay(1);

    /* Step 7: Deassert CPU power-on reset */
    reg = readl(h6_r_cpucfg_membase + H6_POWERON_RST_REG(0));
    writel(reg | BIT(cpu), h6_r_cpucfg_membase + H6_POWERON_RST_REG(0));

    /* Step 8: Deassert CPU core reset */
    reg = readl(h6_cpucfg_membase + H6_CPUCFG_RST_CTRL_REG(0));
    writel(reg | BIT(cpu), h6_cpucfg_membase + H6_CPUCFG_RST_CTRL_REG(0));

    /* Step 9: Assert DBGPWRDUP */
    reg = readl(h6_cpucfg_membase + H6_CPUCFG_DBG_REG0);
    writel(reg | BIT(cpu), h6_cpucfg_membase + H6_CPUCFG_DBG_REG0);

    spin_unlock(&cpu_lock);

    return 0;
}

static const struct smp_operations sun50i_h6_smp_ops __initconst = {
    .smp_prepare_cpus       = sun50i_h6_smp_prepare_cpus,
    .smp_boot_secondary     = sun50i_h6_smp_boot_secondary,
};
CPU_METHOD_OF_DECLARE(sun50i_h6_smp, "allwinner,sun50i-h6", &sun50i_h6_smp_ops);
H6SMP
    echo "  Added H6 SMP support (direct CPU bringup via CPUCFG registers)"
else
    echo "  H6 SMP support already present in platsmp.c"
fi

# --- Patch: Port H6 DTS from arm64 to arm ---
DTS_ARM_DIR="arch/arm/boot/dts/allwinner"
DTS_ARM64_DIR="arch/arm64/boot/dts/allwinner"
mkdir -p "$DTS_ARM_DIR"

# Always re-port the DTS to ensure patches are applied (remove stale copies first)
echo "Porting H6 device tree from arm64 to arm..."
rm -f "$DTS_ARM_DIR"/sun50i-h6*.dts "$DTS_ARM_DIR"/sun50i-h6*.dtsi "$DTS_ARM_DIR"/sunxi-h6-gpio.dtsi 2>/dev/null
cp "$DTS_ARM64_DIR/sun50i-h6.dtsi" "$DTS_ARM_DIR/"
for f in sun50i-h6-orangepi-3.dts sun50i-h6-orangepi-3-lts.dts sun50i-h6-cpu-opp.dtsi sun50i-h6-gpu-opp.dtsi sunxi-h6-gpio.dtsi; do
    [ -f "$DTS_ARM64_DIR/$f" ] && cp "$DTS_ARM64_DIR/$f" "$DTS_ARM_DIR/"
done

# --- PATCH 1: armv8-timer -> armv7-timer (32-bit kernel needs this) ---
sed -i 's/arm,armv8-timer/arm,armv7-timer/g' "$DTS_ARM_DIR/sun50i-h6.dtsi"
echo "  Patched timer: armv8-timer -> armv7-timer"

# --- PATCH 2: Remove PSCI node, set SMP enable-method ---
# Remove the psci node entirely (no TF-A = no PSCI provider)
sed -i '/^\tpsci {/,/^\t};/d' "$DTS_ARM_DIR/sun50i-h6.dtsi"
# Change enable-method from "psci" to "allwinner,sun50i-h6" for direct SMP bringup
sed -i 's/enable-method = "psci";/enable-method = "allwinner,sun50i-h6";/g' "$DTS_ARM_DIR/sun50i-h6.dtsi"
echo "  Removed PSCI node, set enable-method to allwinner,sun50i-h6 for SMP"

# Add to DTS Makefile
DTS_MF="$DTS_ARM_DIR/Makefile"
if [ -f "$DTS_MF" ] && ! grep -q "sun50i-h6-orangepi-3" "$DTS_MF"; then
    echo 'dtb-$(CONFIG_MACH_SUN50I) += sun50i-h6-orangepi-3.dtb' >> "$DTS_MF"
fi
echo "  DTS ported and patched."

# --- Patch: Add H6 to mach-sunxi ---
SUNXI_C="arch/arm/mach-sunxi/sunxi.c"
if [ -f "$SUNXI_C" ] && ! grep -q "sun50i-h6" "$SUNXI_C"; then
    sed -i '/static const char \* const sunxi_dt_compat\[\]/,/};/{
        /NULL/i\
\t"allwinner,sun50i-h6",
    }' "$SUNXI_C"
    echo "  Added H6 to sunxi_dt_compat[]"
fi

# --- Patch: Add MACH_SUN50I to Kconfig ---
KCONFIG="arch/arm/mach-sunxi/Kconfig"
if [ -f "$KCONFIG" ] && ! grep -q "MACH_SUN50I" "$KCONFIG"; then
    sed -i '/config MACH_SUN9I/i\
config MACH_SUN50I\
\tbool "Allwinner sun50i (A64/H5/H6) family - 32-bit mode"\
\tdefault y\
\tdepends on ARCH_SUNXI\
\tselect ARM_GIC\
\tselect ARM_PSCI\
\tselect PINCTRL_SUN50I_H6\
\n' "$KCONFIG"
    echo "  Added MACH_SUN50I to Kconfig"
fi

make ARCH=arm CROSS_COMPILE=$CROSS -j$(nproc) zImage dtbs modules

# Copy outputs
cp arch/arm/boot/zImage "$WORK/output/"
echo "Kernel build complete."
ls -la "$WORK/output/zImage"

# Find the H6 DTB - MUST come from the patched arm32 tree, never arm64
echo "Looking for H6 DTB..."
find arch/arm/boot/dts -name "*h6*orangepi*" 2>/dev/null | head -5 || true

DTB_ARM32="arch/arm/boot/dts/allwinner/sun50i-h6-orangepi-3.dtb"
if [ -f "$DTB_ARM32" ]; then
    echo "Using arm32 DTB (correctly patched with armv7-timer, no PSCI)"
    cp "$DTB_ARM32" "$WORK/output/"
else
    echo "ERROR: arm32 DTB not built! CONFIG_MACH_SUN50I may not be enabled."
    echo "Attempting manual DTB compilation..."
    make ARCH=arm CROSS_COMPILE=$CROSS allwinner/sun50i-h6-orangepi-3.dtb || true
    if [ -f "$DTB_ARM32" ]; then
        cp "$DTB_ARM32" "$WORK/output/"
        echo "Manual DTB build succeeded."
    else
        echo "FATAL: Cannot build arm32 DTB. Check Kconfig for MACH_SUN50I."
        echo "DO NOT fall back to arm64 DTB - it has armv8-timer and PSCI which will hang the 32-bit kernel."
        exit 1
    fi
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
LABEL=rootfs    /       ext4    defaults,noatime        0       1
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
setenv bootargs console=ttyS0,115200 earlycon=uart8250,mmio32,0x05000000 earlyprintk root=LABEL=rootfs rootfstype=ext4 rootwait rw panic=10 loglevel=8
load mmc 0:1 0x42000000 /boot/zImage || load mmc 1:1 0x42000000 /boot/zImage
load mmc 0:1 0x44000000 /boot/sun50i-h6-orangepi-3.dtb || load mmc 1:1 0x44000000 /boot/sun50i-h6-orangepi-3.dtb
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
