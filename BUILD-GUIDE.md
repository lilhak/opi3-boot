# Orange Pi 3 LTS - Complete Boot Build Guide

## 1. Goal Summary

Build a bootable 32GB SD card for the Orange Pi 3 LTS (Allwinner H6, quad
Cortex-A53) that boots to a Devuan Daedalus login shell with all normal system
services running.

**Final architecture:**
- **Kernel:** arm64 (AArch64) Linux 6.6 LTS
- **Userspace:** pure armhf (32-bit) Devuan Daedalus via debootstrap
- **Bootloader:** mainline U-Boot 2024.01+ with TF-A BL31
- **Init:** sysvinit (Devuan default)

The arm64 kernel runs armhf binaries natively via `CONFIG_COMPAT=y` (the
Cortex-A53 supports AArch32 at EL0). This is the standard approach used by
Armbian and every major distro shipping armhf images for 64-bit SoCs.

---

## 2. Feasibility Assessment

### Can the H6 run a 32-bit kernel?

**Theoretically yes, practically no.** The Cortex-A53 supports AArch32 at all
exception levels including EL1 (kernel). However:

| Blocker | Detail |
|---------|--------|
| No 32-bit device tree | `sun50i-h6-*` DTS files exist only under `arch/arm64/boot/dts/allwinner/`. There is no `MACH_SUN50I` in `arch/arm/mach-sunxi/`. |
| No 32-bit kernel config | Mainline Linux has zero H6 support in the 32-bit ARM tree. |
| Boot firmware gap | Mainline TF-A and U-Boot for sun50i_h6 are AArch64-only. Switching to AArch32 before kernel entry requires custom TF-A modifications with no upstream support. |
| No community precedent | No distribution or build system ships a 32-bit kernel for H6. |

**Verdict:** Running a 32-bit kernel on H6 would require porting device trees,
writing custom TF-A state-switching code, and maintaining a fork of multiple
projects. This is months of work with no upstream support path.

### Recommended fallback (adopted)

**arm64 kernel + pure armhf rootfs.** This is the least-risk path:

- Fully upstream-supported boot chain (TF-A + U-Boot + Linux)
- All userspace binaries are 32-bit armhf (satisfies the Devuan armhf goal)
- Kernel module loading is handled by the 64-bit kernel (transparent to userspace)
- Zero patches required against any upstream project

---

## 3. Recommended Boot Path

```
BROM (mask ROM in H6)
  └─> SPL (U-Boot SPL from SD @ 8KB offset)
        └─> BL31 (TF-A, embedded in u-boot-sunxi-with-spl.bin)
              └─> U-Boot proper
                    └─> loads Image + DTB + boot.scr from /boot on ext4
                          └─> arm64 Linux kernel
                                └─> mounts ext4 rootfs
                                      └─> /sbin/init (sysvinit)
                                            └─> login shell
```

All components are mainline. No vendor BSP, no patches.

---

## 4. Assumptions

| Assumption | Notes |
|------------|-------|
| Build host | Debian 12 or Ubuntu 22.04+ x86_64 with `sudo` |
| SD card | 32GB, accessible as `/dev/sdX` (adjust per system) |
| Network | Host has internet for package downloads |
| Serial console | USB-to-UART adapter connected to OPi3 LTS debug UART (115200 8N1) |
| Target kernel | Linux 6.6.y LTS (latest stable point release) |
| Target U-Boot | v2024.01 |
| TF-A | v2.10 |
| No display required | First boot validation via serial console |
| Host packages | Will be installed in step 5.1 |

---

## 5. Step-by-Step Build Instructions

### 5.1 Install host dependencies

```bash
sudo apt update
sudo apt install -y \
  gcc-aarch64-linux-gnu \
  build-essential \
  bison flex libssl-dev libncurses-dev \
  device-tree-compiler \
  python3 python3-dev python3-setuptools python3-pyelftools \
  swig \
  u-boot-tools \
  debootstrap qemu-user-static binfmt-support \
  parted dosfstools e2fsprogs \
  git wget bc cpio kmod \
  devuan-keyring
```

If `devuan-keyring` is not available in your distro's repos, install it
manually:

```bash
wget http://deb.devuan.org/devuan/pool/main/d/devuan-keyring/devuan-keyring_2023.05.20_all.deb
sudo dpkg -i devuan-keyring_2023.05.20_all.deb
```

Ensure QEMU binfmt is active for ARM:

```bash
sudo update-binfmts --enable qemu-arm
sudo update-binfmts --enable qemu-aarch64
```

### 5.2 Set up workspace

```bash
export WORK=$HOME/opi3-build
mkdir -p $WORK/{sources,output,rootfs,mnt}
cd $WORK/sources
```

### 5.3 Build ARM Trusted Firmware (TF-A)

```bash
cd $WORK/sources
git clone --depth 1 --branch v2.10.0 \
  https://git.trustedfirmware.org/TF-A/trusted-firmware-a.git tfa
cd tfa

make CROSS_COMPILE=aarch64-linux-gnu- PLAT=sun50i_h6 bl31 -j$(nproc)

export BL31=$WORK/sources/tfa/build/sun50i_h6/release/bl31.bin
ls -la $BL31   # verify it exists
```

### 5.4 Build U-Boot

```bash
cd $WORK/sources
git clone --depth 1 --branch v2024.01 \
  https://source.denx.de/u-boot/u-boot.git uboot
cd uboot
```

Determine the correct defconfig. Check if the LTS-specific defconfig exists:

```bash
ls configs/orangepi_3_lts_defconfig 2>/dev/null && \
  UBOOT_DEFCONFIG=orangepi_3_lts_defconfig || \
  UBOOT_DEFCONFIG=orangepi_3_defconfig
echo "Using: $UBOOT_DEFCONFIG"
```

Build:

```bash
make CROSS_COMPILE=aarch64-linux-gnu- $UBOOT_DEFCONFIG
make CROSS_COMPILE=aarch64-linux-gnu- -j$(nproc)

cp u-boot-sunxi-with-spl.bin $WORK/output/
ls -la $WORK/output/u-boot-sunxi-with-spl.bin
```

### 5.5 Build Linux kernel

```bash
cd $WORK/sources
git clone --depth 1 --branch v6.6.70 \
  https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git linux
cd linux
```

Generate defconfig and apply required options:

```bash
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- defconfig
```

Apply essential config overrides:

```bash
./scripts/config --enable CONFIG_COMPAT
./scripts/config --enable CONFIG_SMP
./scripts/config --enable CONFIG_ARCH_SUNXI
./scripts/config --enable CONFIG_SUN50I_H6_CCU
./scripts/config --enable CONFIG_DWMAC_SUN8I
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

make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- olddefconfig
```

Build:

```bash
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- -j$(nproc) Image dtbs modules
```

Install outputs:

```bash
cp arch/arm64/boot/Image $WORK/output/

# Copy DTB - prefer LTS variant if it exists
if [ -f arch/arm64/boot/dts/allwinner/sun50i-h6-orangepi-3-lts.dtb ]; then
  cp arch/arm64/boot/dts/allwinner/sun50i-h6-orangepi-3-lts.dtb $WORK/output/
  export DTB_NAME=sun50i-h6-orangepi-3-lts.dtb
else
  cp arch/arm64/boot/dts/allwinner/sun50i-h6-orangepi-3.dtb $WORK/output/
  export DTB_NAME=sun50i-h6-orangepi-3.dtb
  echo "WARNING: Using non-LTS DTB. Ethernet PHY may need DTB patches."
fi
echo "DTB: $DTB_NAME"

# Modules will be installed into rootfs later
export KERNEL_SRC=$WORK/sources/linux
```

### 5.6 Create Devuan Daedalus rootfs

First, ensure the debootstrap `daedalus` script exists:

```bash
if [ ! -f /usr/share/debootstrap/scripts/daedalus ]; then
  sudo ln -s sid /usr/share/debootstrap/scripts/daedalus
fi
```

Run first-stage debootstrap:

```bash
sudo debootstrap --arch=armhf --foreign --variant=minbase \
  --include=sysvinit-core,sysv-rc,eudev,kmod,iproute2,ifupdown,\
isc-dhcp-client,openssh-server,procps,nano,wget,ca-certificates,\
locales,apt-transport-https,dialog,less \
  daedalus $WORK/rootfs http://deb.devuan.org/merged/
```

Copy QEMU static binary and run second stage:

```bash
sudo cp /usr/bin/qemu-arm-static $WORK/rootfs/usr/bin/
sudo chroot $WORK/rootfs /debootstrap/debootstrap --second-stage
```

### 5.7 Configure the rootfs

Run the configuration script (see `scripts/configure-rootfs.sh` in this repo):

```bash
sudo cp scripts/configure-rootfs.sh $WORK/rootfs/tmp/
sudo chroot $WORK/rootfs /bin/bash /tmp/configure-rootfs.sh
```

### 5.8 Install kernel modules into rootfs

```bash
cd $KERNEL_SRC
sudo make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- \
  INSTALL_MOD_PATH=$WORK/rootfs modules_install
```

### 5.9 Create boot.scr

```bash
cat > $WORK/output/boot.cmd << 'BOOTCMD'
setenv bootargs console=ttyS0,115200 root=/dev/mmcblk0p1 rootfstype=ext4 rootwait rw panic=10 loglevel=7
load mmc 0:1 ${kernel_addr_r} /boot/Image
load mmc 0:1 ${fdt_addr_r} /boot/${fdtfile}
booti ${kernel_addr_r} - ${fdt_addr_r}
BOOTCMD

mkimage -C none -A arm64 -T script -d $WORK/output/boot.cmd $WORK/output/boot.scr
```

### 5.10 Assemble the SD card

**WARNING: This writes raw to a block device. Triple-check your device path.**

Run the SD card assembly script (see `scripts/assemble-sd.sh`):

```bash
sudo scripts/assemble-sd.sh /dev/sdX
```

Or do it manually:

```bash
export SD=/dev/sdX   # CHANGE THIS

# Wipe and partition
sudo dd if=/dev/zero of=$SD bs=1M count=16
sudo parted -s $SD mklabel msdos
sudo parted -s $SD mkpart primary ext4 1MiB 100%

# Write bootloader (raw, at 8KB offset)
sudo dd if=$WORK/output/u-boot-sunxi-with-spl.bin of=$SD bs=1k seek=8 conv=notrunc

# Format root partition
sudo mkfs.ext4 -L rootfs ${SD}1

# Mount and populate
sudo mount ${SD}1 $WORK/mnt
sudo cp -a $WORK/rootfs/* $WORK/mnt/

# Install boot files
sudo mkdir -p $WORK/mnt/boot
sudo cp $WORK/output/Image $WORK/mnt/boot/
sudo cp $WORK/output/$DTB_NAME $WORK/mnt/boot/
sudo cp $WORK/output/boot.scr $WORK/mnt/boot/

# Set fdtfile for boot.scr
echo "allwinner/$DTB_NAME" | sudo tee $WORK/mnt/boot/fdtfile

sudo sync
sudo umount $WORK/mnt
```

---

## 6. Bootloader Config

### U-Boot environment

The `boot.scr` script (section 5.9) handles kernel loading. Key variables:

| Variable | Value | Purpose |
|----------|-------|---------|
| `bootargs` | `console=ttyS0,115200 root=/dev/mmcblk0p1 rootfstype=ext4 rootwait rw` | Kernel command line |
| `kernel_addr_r` | Set by board defconfig (typically `0x40080000`) | Kernel load address |
| `fdt_addr_r` | Set by board defconfig (typically `0x4FA00000`) | DTB load address |
| `fdtfile` | `allwinner/sun50i-h6-orangepi-3.dtb` | Device tree path |

### U-Boot boot sequence

U-Boot auto-loads `boot.scr` from partition 1 of MMC device 0 (the SD card).
The script:

1. Sets kernel command line arguments
2. Loads the `Image` (arm64 kernel) to `kernel_addr_r`
3. Loads the DTB to `fdt_addr_r`
4. Calls `booti` to boot the arm64 Image

### Fallback: U-Boot interactive

If `boot.scr` fails, interrupt autoboot via serial and type:

```
setenv bootargs console=ttyS0,115200 root=/dev/mmcblk0p1 rootfstype=ext4 rootwait rw
load mmc 0:1 ${kernel_addr_r} /boot/Image
load mmc 0:1 ${fdt_addr_r} /boot/allwinner/sun50i-h6-orangepi-3.dtb
booti ${kernel_addr_r} - ${fdt_addr_r}
```

---

## 7. Kernel Config

### Base config

Start from `defconfig` for arm64 which enables broad hardware support. Critical
options to verify:

```
# SoC support
CONFIG_ARCH_SUNXI=y

# CPU / SMP
CONFIG_SMP=y
CONFIG_NR_CPUS=4

# 32-bit userspace compatibility (THIS IS CRITICAL)
CONFIG_COMPAT=y

# Clock controller
CONFIG_SUN50I_H6_CCU=y

# MMC (SD card boot)
CONFIG_MMC=y
CONFIG_MMC_SUNXI=y

# Filesystem
CONFIG_EXT4_FS=y
CONFIG_TMPFS=y

# Serial console
CONFIG_SERIAL_8250=y
CONFIG_SERIAL_8250_DW=y
CONFIG_SERIAL_8250_CONSOLE=y

# Device hotplug
CONFIG_DEVTMPFS=y
CONFIG_DEVTMPFS_MOUNT=y

# USB
CONFIG_USB_EHCI_HCD=y
CONFIG_USB_OHCI_HCD=y
CONFIG_USB_STORAGE=y
CONFIG_PHY_SUN50I_USB3=y

# Ethernet
CONFIG_DWMAC_SUN8I=y
CONFIG_STMMAC_ETH=y

# PMIC (AXP805/AXP806)
CONFIG_SUNXI_RSB=y
CONFIG_MFD_AXP20X_RSB=y
CONFIG_REGULATOR_AXP20X=y

# Thermal
CONFIG_SUN50I_H6_THS=y
```

### Verifying CONFIG_COMPAT

After building, confirm:

```bash
grep CONFIG_COMPAT $WORK/sources/linux/.config
# Must show: CONFIG_COMPAT=y
```

If `CONFIG_COMPAT` is not set, armhf binaries will fail with
`Exec format error`. This is the single most important config option.

---

## 8. Devuan Daedalus Rootfs Setup

### Package selection rationale

| Package | Why |
|---------|-----|
| `sysvinit-core` | Devuan's init (PID 1) |
| `sysv-rc` | Runlevel management, `/etc/init.d` |
| `eudev` | Device manager (Devuan's non-systemd udev fork) |
| `kmod` | `modprobe`, `lsmod` for kernel modules |
| `iproute2` | `ip` command for networking |
| `ifupdown` | `/etc/network/interfaces` support |
| `isc-dhcp-client` | DHCP for automatic network config |
| `openssh-server` | Remote access (headless board) |
| `procps` | `ps`, `top`, `free` |

### sources.list

```
deb http://deb.devuan.org/merged/ daedalus main
deb http://deb.devuan.org/merged/ daedalus-updates main
deb http://deb.devuan.org/merged/ daedalus-security main
```

### Key configuration files

**`/etc/fstab`:**
```
/dev/mmcblk0p1  /         ext4  defaults,noatime  0  1
tmpfs           /tmp      tmpfs defaults          0  0
proc            /proc     proc  defaults          0  0
sysfs           /sys      sysfs defaults          0  0
devpts          /dev/pts  devpts defaults         0  0
```

**`/etc/inittab` (serial console):**
```
T0:2345:respawn:/sbin/getty -L ttyS0 115200 vt100
```

**`/etc/hostname`:**
```
opi3lts
```

**`/etc/network/interfaces`:**
```
auto lo
iface lo inet loopback

auto eth0
iface eth0 inet dhcp
```

See `scripts/configure-rootfs.sh` for the complete configuration script.

---

## 9. SD Card Image / Flash Layout

### Physical layout

```
Offset          Content                     Size
────────────────────────────────────────────────────
0x0000          MBR + partition table       512 B
0x2000 (8 KB)   u-boot-sunxi-with-spl.bin  ~800 KB
0x100000 (1 MB) Partition 1 start           ~31 GB
                └── ext4 filesystem
                    ├── /boot/Image
                    ├── /boot/sun50i-h6-orangepi-3.dtb
                    ├── /boot/boot.scr
                    ├── /bin, /sbin, /usr, /etc ...
                    └── /lib/modules/6.6.70/
```

### Partition table

| # | Type | Start | End | FS | Mount |
|---|------|-------|-----|----|-------|
| 1 | Linux (0x83) | 1 MiB | 100% | ext4 | / |

Single partition. No separate /boot needed. U-Boot reads ext4 natively.

### dd command for bootloader

```bash
sudo dd if=u-boot-sunxi-with-spl.bin of=/dev/sdX bs=1024 seek=8 conv=notrunc
```

The `conv=notrunc` is critical -- it prevents dd from truncating the device
and destroying the partition table if the bootloader is written after
partitioning.

---

## 10. Validation Checklist

Run through this checklist after inserting the SD card and powering on with
serial console attached (115200 8N1):

### Boot stages

- [ ] **BROM output visible** -- H6 BROM prints a short message. If nothing
      appears, check UART wiring (TX/RX/GND) and baud rate.
- [ ] **U-Boot SPL starts** -- Look for `U-Boot SPL` banner. If missing,
      bootloader is not at correct SD offset.
- [ ] **U-Boot proper starts** -- Look for `U-Boot 2024.01` banner and board
      identification.
- [ ] **boot.scr loads** -- `## Executing script at ...` message.
- [ ] **Kernel Image loads** -- `Loading kernel from ...` or size indication.
- [ ] **DTB loads** -- `Loading device tree from ...`
- [ ] **Kernel starts** -- `Booting Linux on physical CPU 0x0` message.
- [ ] **SMP enabled** -- `smp: Bringing up secondary CPUs ...` followed by
      `CPU1`, `CPU2`, `CPU3` online messages. All 4 cores must come up.
- [ ] **Root filesystem mounts** -- `VFS: Mounted root (ext4 filesystem)`.
- [ ] **Init starts** -- `INIT: version X.XX booting`.
- [ ] **Services start** -- `eudev`, `networking`, `ssh` init scripts run.
- [ ] **Login prompt** -- `opi3lts login:` appears on serial console.
- [ ] **Login works** -- Can log in as root with the configured password.

### Post-boot verification

```bash
# All 4 CPUs online
nproc                    # expect: 4
cat /proc/cpuinfo        # 4 processor entries

# Architecture check
uname -m                 # expect: aarch64
file /bin/ls             # expect: ELF 32-bit LSB ... ARM ...
dpkg --print-architecture  # expect: armhf

# Filesystem
df -h /                  # root partition mounted rw, ~30GB available
mount | grep mmcblk0p1   # ext4, rw

# Networking
ip addr show eth0        # has an IP via DHCP
ping -c 3 1.1.1.1        # external connectivity

# Services
pgrep -a sshd            # sshd running
pgrep -a getty            # getty on ttyS0
pidof init               # PID 1 is init
```

---

## 11. Debugging Matrix

| Symptom | Likely cause | Fix |
|---------|-------------|-----|
| No serial output at all | Wrong UART pins, wrong baud rate, or board not powering on | Verify TX→RX, RX→TX, GND→GND. Use 115200 8N1. Check 5V power supply (≥2A). |
| BROM prints then hangs | SPL not found at sector 16 | Re-dd the bootloader: `dd if=u-boot-sunxi-with-spl.bin of=/dev/sdX bs=1k seek=8` |
| `SPL: MMC init failed` | Bad SD card or incompatible card | Try a different SD card. Use a name-brand Class 10 / UHS-I card. |
| U-Boot starts, `boot.scr` not found | Wrong partition layout or missing boot.scr | Check partition starts at 1MB. Verify `boot.scr` is in `/boot/` on the partition. |
| `Bad Linux ARM64 Image magic!` | Corrupt kernel Image or wrong load address | Re-copy Image. Verify it's the uncompressed arm64 Image (not zImage). |
| `FDT: fdt_check_header() failed` | DTB not found or corrupt | Check DTB path matches what boot.scr expects. Verify fdtfile variable. |
| Kernel boots, `SMP: Total of 1 processors activated` | SMP or PSCI issue | Check `CONFIG_SMP=y`. Verify TF-A (BL31) is correctly built for sun50i_h6 -- PSCI brings up secondaries. |
| `VFS: Cannot open root device` | Wrong root= parameter or partition not found | Verify `root=/dev/mmcblk0p1`. Try adding `rootdelay=5`. Check partition exists with `fdisk -l`. |
| `Kernel panic - not syncing: No init found` | rootfs missing /sbin/init or library mismatch | Verify debootstrap completed. Check `/sbin/init` exists and is armhf ELF. Run `file rootfs/sbin/init`. |
| `Exec format error` for all binaries | `CONFIG_COMPAT` not enabled in kernel | Rebuild kernel with `CONFIG_COMPAT=y`. This enables 32-bit binary execution on arm64. |
| Init starts but services fail | Missing eudev/kmod packages | Chroot into rootfs and run `apt install eudev kmod`. |
| No ethernet / `eth0` absent | DTB mismatch (LTS vs non-LTS board) | Need LTS-specific DTB with correct PHY regulator. See section 12. |
| `DHCP: No lease` | Ethernet PHY not initialized (PMIC regulator) | Check dmesg for `dwmac-sun8i` and `axp` errors. May need DTB fix for PHY power. |
| SSH connection refused | openssh-server not installed or host keys missing | Chroot: `apt install openssh-server`, then `ssh-keygen -A`. |
| Kernel modules not loading | Modules not installed or version mismatch | Re-run `make modules_install INSTALL_MOD_PATH=...`. Verify `/lib/modules/$(uname -r)/` exists. |

---

## 12. Risks / Constraints

### Risk 1: Device tree mismatch (HIGH)

The Orange Pi 3 LTS DTB (`sun50i-h6-orangepi-3-lts.dts`) may not yet be in
the mainline kernel tree at v6.6.x. The non-LTS DTB (`sun50i-h6-orangepi-3.dts`)
will boot the board but Ethernet may not work due to PHY power supply
differences.

**Mitigation:** The build scripts check for the LTS DTB and fall back to the
non-LTS version. If Ethernet is broken, obtain the LTS DTS from:
1. Armbian's patch set: <https://github.com/armbian/build/tree/main/patch/kernel>
2. The orangepi vendor kernel: <https://github.com/orangepi-xunlong/linux-orangepi>
3. Manual patch: Copy `sun50i-h6-orangepi-3.dts`, adjust the PHY regulator
   node for the LTS board's power design.

### Risk 2: U-Boot defconfig availability (MEDIUM)

`orangepi_3_lts_defconfig` may not exist in U-Boot v2024.01. The scripts fall
back to `orangepi_3_defconfig` which works for the non-LTS board and should
boot on the LTS variant (same SoC, same DRAM, same SD interface).

### Risk 3: PMIC initialization (MEDIUM)

The H6 uses an AXP805/AXP806 PMIC over RSB bus. If PMIC drivers fail, voltage
regulators may not enable properly, causing peripheral failures. Ensure
`CONFIG_SUNXI_RSB=y` and `CONFIG_MFD_AXP20X_RSB=y` in the kernel config.

### Risk 4: 32-bit kernel not viable (RESOLVED)

As documented in section 2, a 32-bit kernel is not practical for H6. The
adopted arm64-kernel + armhf-userspace approach is the industry standard.

### Risk 5: debootstrap keyring (LOW)

Debian hosts may not have `devuan-keyring`. The build script handles this by
downloading and installing it manually if needed.

### Constraint: No GPU / display acceleration

Mainline kernel support for H6 GPU (Mali-T720) is limited. This build targets
serial-console / SSH operation only. Adding display support would require
additional packages (Xorg, mesa) and is out of scope.

---

## 13. First Coding Tasks

These are the immediate implementation tasks, in dependency order:

### Task 1: Create `scripts/build-tfa.sh`
Build TF-A for sun50i_h6. Clones repo, builds bl31.bin, exports path.

### Task 2: Create `scripts/build-uboot.sh`
Build U-Boot with BL31. Handles LTS vs non-LTS defconfig detection.

### Task 3: Create `scripts/build-kernel.sh`
Build arm64 kernel with all required configs. Produces Image, DTB, modules.

### Task 4: Create `scripts/create-rootfs.sh`
Debootstrap Devuan Daedalus armhf rootfs with all packages and configuration.

### Task 5: Create `scripts/configure-rootfs.sh`
In-chroot configuration: fstab, inittab, networking, hostname, root password,
SSH keys, apt sources.

### Task 6: Create `scripts/assemble-sd.sh`
Partition SD card, write bootloader, format ext4, copy rootfs and boot files.

### Task 7: Create `scripts/build-all.sh`
Master script that runs tasks 1-6 in sequence.

### Task 8: Validate with real hardware
Insert SD card, connect serial console, power on, verify all checklist items
from section 10.

---

## Appendix A: Quick Reference Commands

```bash
# Full build (after cloning this repo)
export WORK=$HOME/opi3-build
./scripts/build-all.sh

# Write to SD card
sudo ./scripts/assemble-sd.sh /dev/sdX

# Serial console (Linux host)
screen /dev/ttyUSB0 115200

# Serial console (macOS host)
screen /dev/tty.usbserial-* 115200
```

## Appendix B: DTB Patching for LTS Board

If using the non-LTS DTB and Ethernet doesn't work, you may need to patch the
PHY regulator. Create `sun50i-h6-orangepi-3-lts.dts`:

```dts
// SPDX-License-Identifier: (GPL-2.0+ OR MIT)
// Based on sun50i-h6-orangepi-3.dts with LTS-specific PHY power fixes

#include "sun50i-h6-orangepi-3.dts"

/ {
    model = "OrangePi 3 LTS";
    compatible = "xunlong,orangepi-3-lts", "allwinner,sun50i-h6";
};

/* Adjust PHY regulator if needed - the LTS board may use a different
   power rail for the Ethernet PHY. Check schematics. */
```

Compile with:

```bash
cpp -nostdinc -I $KERNEL_SRC/include -undef -x assembler-with-cpp \
  sun50i-h6-orangepi-3-lts.dts | \
  dtc -I dts -O dtb -o sun50i-h6-orangepi-3-lts.dtb
```
