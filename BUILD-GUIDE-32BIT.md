# Orange Pi 3 LTS - Native AArch32 Boot Guide

## 1. Goal

Build a bootable SD card for the Orange Pi 3 LTS (Allwinner H6, quad
Cortex-A53) that boots **entirely in 32-bit AArch32 mode** to a Devuan
Daedalus armhf login shell.

**Architecture:**
- **Bootloader:** 32-bit U-Boot (SPL + proper), patched mainline
- **Kernel:** 32-bit armhf zImage with ported H6 device tree
- **Userspace:** pure armhf (32-bit) Devuan Daedalus via debootstrap
- **Init:** sysvinit (Devuan default)
- **TF-A:** Not used. No RMR switch. System stays AArch32 from cold reset.

**Boot chain:**
```
Cold reset → AArch32
  → BROM loads SPL (AArch32) from SD @ 8KB
    → SPL initializes DRAM (AArch32)
      → SPL loads U-Boot proper (AArch32)
        → U-Boot loads 32-bit zImage + DTB
          → 32-bit Linux kernel boots
            → Devuan armhf userspace
```

---

## 2. Why This Works

All Allwinner ARMv8 SoCs cold-reset into AArch32. The BROM is 32-bit ARM
code. The standard U-Boot SPL triggers an RMR warm reset to switch to AArch64.
**If we skip the RMR switch, the system stays in AArch32 natively.**

The Cortex-A53 supports AArch32 at all exception levels (EL0/EL1/EL2/EL3),
so running a 32-bit kernel is architecturally valid.

See `docs/h6-32bit-research.md` for detailed research findings.

---

## 3. Prerequisites

### Build Host
- Debian 12 or Ubuntu 22.04+ (x86_64)
- Internet access for source downloads
- ~10GB free disk space

### Hardware
- Orange Pi 3 LTS board
- 32GB SD card (Class 10 / UHS-I recommended)
- USB-to-UART adapter for serial console (115200 8N1)
- 5V/2A power supply

### Install Host Dependencies

```bash
sudo apt update
sudo apt install -y \
  gcc-arm-linux-gnueabihf \
  build-essential \
  bison flex libssl-dev libncurses-dev \
  device-tree-compiler \
  python3 python3-dev python3-setuptools python3-pyelftools \
  swig \
  u-boot-tools \
  debootstrap qemu-user-static binfmt-support \
  parted dosfstools e2fsprogs \
  git wget bc cpio kmod

# Devuan keyring (if not in distro repos)
wget http://deb.devuan.org/devuan/pool/main/d/devuan-keyring/devuan-keyring_2023.05.20_all.deb
sudo dpkg -i devuan-keyring_2023.05.20_all.deb

sudo update-binfmts --enable qemu-arm
```

**Note:** We need `gcc-arm-linux-gnueabihf` (32-bit ARM), NOT
`gcc-aarch64-linux-gnu` (64-bit). No TF-A cross-compiler needed.

---

## 4. Build Steps

### 4.1 Set Up Workspace

```bash
export WORK=$HOME/opi3-build
mkdir -p $WORK/{sources,output,rootfs,mnt}
```

### 4.2 Build 32-bit U-Boot

```bash
./scripts/build-uboot-arm32.sh
```

This script:
1. Clones mainline U-Boot (v2024.01)
2. Patches the Kconfig to allow 32-bit builds for H6
   (`CONFIG_SUNXI_ARMV8_32BIT_BUILD=y`)
3. Creates a custom defconfig with H6 LPDDR3 DRAM settings
4. Builds with `ARCH=arm CROSS_COMPILE=arm-linux-gnueabihf-`
5. Produces `$WORK/output/u-boot-sunxi-with-spl-arm32.bin`

**No TF-A/BL31 needed.** The RMR switch code is only included when
`CONFIG_ARM_BOOT_HOOK_RMR` is set (which requires ARM64).

### 4.3 Build 32-bit Kernel

```bash
./scripts/build-kernel-arm32.sh
```

This script:
1. Clones Linux 6.6 LTS
2. Ports the H6 device tree from `arch/arm64/boot/dts/` to `arch/arm/boot/dts/`
   - Patches `arm,armv8-timer` → `arm,armv7-timer`
   - Adds H6 compatible string to `arch/arm/mach-sunxi/sunxi.c`
3. Configures from `multi_v7_defconfig` with H6 driver overrides
4. Builds zImage, DTBs, and modules
5. Produces `$WORK/output/zImage` and `$WORK/output/sun50i-h6-orangepi-3.dtb`

### 4.4 Create Devuan rootfs

```bash
./scripts/create-rootfs.sh
```

This is identical to the 64-bit build — same armhf Devuan Daedalus rootfs.
The rootfs doesn't care whether the kernel is 32-bit or 64-bit.

### 4.5 Install Kernel Modules

```bash
cd $WORK/sources/linux-arm32
sudo make ARCH=arm CROSS_COMPILE=arm-linux-gnueabihf- \
  INSTALL_MOD_PATH=$WORK/rootfs modules_install
```

### 4.6 Configure Rootfs

```bash
sudo cp scripts/configure-rootfs.sh $WORK/rootfs/tmp/
sudo chroot $WORK/rootfs /bin/bash /tmp/configure-rootfs.sh
```

### 4.7 Assemble SD Card

```bash
sudo ./scripts/assemble-sd-arm32.sh /dev/sdX
```

---

## 5. SD Card Layout

```
Offset          Content                              Size
────────────────────────────────────────────────────────────
0x0000          MBR + partition table                512 B
0x2000 (8 KB)   u-boot-sunxi-with-spl-arm32.bin     ~400 KB
0x100000 (1 MB) Partition 1 start                    ~31 GB
                └── ext4 filesystem
                    ├── /boot/zImage
                    ├── /boot/sun50i-h6-orangepi-3.dtb
                    ├── /boot/boot.scr
                    ├── /bin, /sbin, /usr, /etc ...
                    └── /lib/modules/6.6.70/
```

The SD layout is identical to the 64-bit version. The BROM loads from
the same offset (8KB) regardless of whether the SPL is 32 or 64-bit.

---

## 6. Boot Configuration

### boot.scr

```
setenv bootargs console=ttyS0,115200 root=/dev/mmcblk0p1 rootfstype=ext4 rootwait rw panic=10 loglevel=7
load mmc 0:1 0x42000000 /boot/zImage
load mmc 0:1 0x44000000 /boot/sun50i-h6-orangepi-3.dtb
bootz 0x42000000 - 0x44000000
```

Key differences from 64-bit:
- Loads `zImage` (not `Image`)
- Uses `bootz` (not `booti`)
- Uses fixed load addresses (0x42000000 for kernel, 0x44000000 for DTB)
- Architecture is `arm` (not `arm64`) in `mkimage`

### U-Boot Interactive Fallback

If `boot.scr` fails, interrupt autoboot and type:
```
load mmc 0:1 0x42000000 /boot/zImage
load mmc 0:1 0x44000000 /boot/sun50i-h6-orangepi-3.dtb
setenv bootargs console=ttyS0,115200 root=/dev/mmcblk0p1 rootfstype=ext4 rootwait rw
bootz 0x42000000 - 0x44000000
```

---

## 7. Validation Checklist

### Boot Stages

- [ ] **BROM output** — H6 BROM prints a short message (AArch32)
- [ ] **U-Boot SPL** — `U-Boot SPL` banner, DRAM size detected
- [ ] **U-Boot proper** — `U-Boot 2024.01` banner (should show ARM, not AArch64)
- [ ] **boot.scr loads** — `## Executing script at ...`
- [ ] **zImage loads** — Kernel loading message
- [ ] **DTB loads** — Device tree loading
- [ ] **Kernel starts** — `Booting Linux on physical CPU 0x0`
- [ ] **Root mounts** — `VFS: Mounted root (ext4 filesystem)`
- [ ] **Init starts** — `INIT: version X.XX booting`
- [ ] **Login prompt** — `opi3lts login:`

### Post-Boot Verification

```bash
# Architecture — should be armv7l, NOT aarch64
uname -m                     # expect: armv7l
file /bin/ls                 # expect: ELF 32-bit LSB ... ARM ...
dpkg --print-architecture    # expect: armhf

# CPU
cat /proc/cpuinfo            # Initially 1 CPU (no SMP without TF-A)
nproc                        # expect: 1 (initially)

# Filesystem
df -h /
mount | grep mmcblk0p1

# Networking
ip addr show eth0
ping -c 3 1.1.1.1
```

---

## 8. Known Limitations

### Single Core Initially

Without TF-A providing PSCI, only the boot CPU runs. `nproc` will show 1
instead of 4. This is fine for initial bring-up and most server workloads.

Options for SMP are documented in `docs/h6-32bit-research.md` section 3.4:
1. Port sunxi SMP bringup code for H6 CPUCFG registers
2. Write a minimal AArch32 PSCI shim
3. Use spin-table method

### Device Tree Port Quality

The H6 DTS is mechanically ported from arm64. Most peripherals work because
they use the same IP blocks and architecture-neutral drivers. If a specific
peripheral doesn't work:

1. Check `dmesg` for driver probe failures
2. Compare with working sun8i DTS for syntax differences
3. Some H6-specific peripherals (PCIe, USB3) may need additional porting

### No GPU Acceleration

Mali-T720 support in 32-bit mode is limited. This build targets
serial-console / SSH headless operation.

---

## 9. Differences from 64-bit Build

| Aspect | 64-bit (BUILD-GUIDE.md) | 32-bit (this guide) |
|--------|------------------------|---------------------|
| Cross compiler | `aarch64-linux-gnu-` | `arm-linux-gnueabihf-` |
| TF-A | Required (BL31) | Not needed |
| U-Boot ARCH | `arm64` | `arm` (patched Kconfig) |
| Kernel ARCH | `arm64` | `arm` |
| Kernel image | `Image` | `zImage` |
| Boot command | `booti` | `bootz` |
| uname -m | `aarch64` | `armv7l` |
| CONFIG_COMPAT | Required (for armhf bins) | Not needed (native) |
| CPU cores | 4 (via PSCI) | 1 (initially) |
| RMR switch | Yes (AArch32→AArch64) | No (stays AArch32) |
| Upstream status | Fully mainline | Requires patches |

---

## 10. Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| No serial output | UART wiring, baud rate | Check TX→RX, RX→TX, GND→GND. 115200 8N1. |
| BROM then hang | SPL not found at 8KB | Re-dd bootloader: `dd if=...arm32.bin of=/dev/sdX bs=1k seek=8` |
| `Bad Linux ARM Image magic!` | Wrong kernel format | Ensure you're loading `zImage`, not `Image`. Check `bootz` vs `booti`. |
| U-Boot build fails on Kconfig | Patch didn't apply | Check U-Boot version matches v2024.01. Manually inspect Kconfig changes. |
| Kernel DTS compile error | Port incompatibility | Check the DTSI for arm64-specific nodes. Common fix: timer compatible string. |
| Kernel boots, no MMC | Missing MMC driver | Verify `CONFIG_MMC_SUNXI=y` in .config |
| `Exec format error` | Running 64-bit binary on 32-bit kernel | All binaries must be armhf. Check with `file /path/to/binary`. |
| Only 1 CPU | Expected — no PSCI | See section 8 for SMP options. |

---

## 11. Quick Reference

```bash
# Full build
export WORK=$HOME/opi3-build
./scripts/build-uboot-arm32.sh
./scripts/build-kernel-arm32.sh
./scripts/create-rootfs.sh
cd $WORK/sources/linux-arm32 && sudo make ARCH=arm CROSS_COMPILE=arm-linux-gnueabihf- INSTALL_MOD_PATH=$WORK/rootfs modules_install
sudo ./scripts/assemble-sd-arm32.sh /dev/sdX

# Serial console
screen /dev/ttyUSB0 115200       # Linux
screen /dev/tty.usbserial-* 115200  # macOS
```
