# H6 AArch32-Native Boot: Research Findings

## 1. The Core Insight

All Allwinner ARMv8 SoCs (A64, H5, H6, H616) cold-reset into AArch32. The BROM
is 32-bit ARM code. The transition to AArch64 is performed by U-Boot SPL via the
ARM Reset Management Register (RMR), which triggers a warm reset into AArch64.

**If we skip the RMR switch, the entire boot chain stays in AArch32 natively.**

### Evidence from U-Boot source

`arch/arm/mach-sunxi/rmr_switch.S`:
```
@ All 64-bit capable Allwinner SoCs reset in AArch32 (and continue to
@ execute the Boot ROM in this state), so we need to switch to AArch64
@ at some point.
```

`board/sunxi/README.sunxi64`:
```
Both U-Boot proper and the SPL are using the 64-bit mode. As the boot ROM
enters the SPL still in AArch32 secure SVC mode, there is some shim code to
enter AArch64 very early.
```

The RMR shim is embedded via `CONFIG_ARM_BOOT_HOOK_RMR` in
`arch/arm/include/asm/arch-sunxi/boot0.h`. It saves CPU state, writes the
AArch64 entry point to the RVBAR register via an Allwinner MMIO alias, then
triggers a warm reset with the AArch64 flag set.

---

## 2. U-Boot 32-bit SPL for H6

### 2.1 DRAM Controller Code

**File:** `arch/arm/mach-sunxi/dram_sun50i_h6.c` (544 lines)

**Architecture-neutral:** Uses only 32-bit register operations:
- `writel()`, `readl()`, `setbits_le32()`, `clrbits_le32()`
- Returns `unsigned long` (works in both 32 and 64-bit)
- No inline assembly or architecture-specific code

**Dependencies:**
- `CONFIG_DRAM_SUN50I_H6` - enables compilation
- `CONFIG_DRAM_CLK` (default 744 MHz for H6)
- `CONFIG_SUNXI_DRAM_H6_LPDDR3` or `CONFIG_SUNXI_DRAM_H6_DDR3_1333`
- `CONFIG_DRAM_ZQ`, `CONFIG_DRAM_ODT_EN`

**DRAM controller architecture:** 3 parts - COM (Allwinner-specific), CTL
(DesignWare memory controller), PHY (DesignWare). The H6 moved address mapping
from COM to CTL using standard ADDRMAP registers.

**Conclusion: The DRAM init code will compile and run in AArch32 mode.**

### 2.2 Kconfig Blocker

Current mainline `arch/arm/mach-sunxi/Kconfig`:
```
config MACH_SUN50I_H6
    bool "sun50i (Allwinner H6)"
    select ARM64          # <-- This forces 64-bit
    select DRAM_SUN50I_H6
    select SUN50I_GEN_H6
```

`MACH_SUN50I_H6` hard-selects `ARM64`. Cannot build ARCH=arm without patching.

### 2.3 Prior Art: Andre Przywara's 32-bit SPL Patches (2019)

Patch series: "[PATCH 0/9] sunxi: Allow FEL capable SPLs with 32bit builds"
(February 2019, Andre Przywara @ ARM)

Introduced `CONFIG_SUNXI_ARMV8_32BIT_BUILD` which:
- Toggles between `CONFIG_ARM64` and `CONFIG_CPU_V7A`
- Allows building 32-bit SPL for ARMv8 SoCs
- Uses compact Thumb2 encoding for smaller SPL images
- Enables FEL booting (USB-OTG boot via 32-bit BROM)

**Defconfig added:** `sun50i-h6-lpddr3-spl_defconfig`
```
CONFIG_ARM=y
CONFIG_ARCH_SUNXI=y
CONFIG_SPL=y
CONFIG_MACH_SUN50I_H6=y
CONFIG_SUNXI_ARMV8_32BIT_BUILD=y
CONFIG_MMC_SUNXI_SLOT_EXTRA=2
CONFIG_NR_DRAM_BANKS=1
CONFIG_DEFAULT_DEVICE_TREE="sun50i-h6-pine-h64"
```

**Status: NOT MERGED into mainline.** The patches remain in apritzel's
`sunxi64-fel32` branch on GitHub.

**Key difference from our use case:** Those patches built a 32-bit SPL that
still switched to AArch64 for U-Boot proper. We want everything 32-bit.

### 2.4 hexdump0815 libdram Approach

Repository: `hexdump0815/u-boot-misc`

Uses Allwinner BSP's proprietary `libdram` blob (32-bit library) linked with a
32-bit SPL. The output `sunxi-spl.bin-arm32` is concatenated with a 64-bit
U-Boot proper.

**Problems:**
- Requires Allwinner H6-BSP-1.0.tgz (proprietary, redistribution forbidden)
- GPL violation concerns (proprietary blob + GPL U-Boot)
- Maximum 2GB DRAM detection
- Requires two compilation environments (32-bit + 64-bit)

**Not recommended for our use case.**

### 2.5 boot0 Binary Availability

Checked `smaeul/sunxi-blobs` repository. The H6 directory (`sun50iw6p1`)
contains:
- `nbrom/` - NAND Boot ROM dump
- `sbrom/` - SPI Boot ROM dump
- `arisc_*` - ARISC coprocessor firmware

**No boot0 binary available for H6.** The repository has BROM dumps (for
reverse engineering) and ARISC firmware, but not the boot0/boot1 bootloader
binaries that Allwinner ships in their SDK.

### 2.6 Recommended U-Boot Approach

**Patched mainline U-Boot** (based on Andre Przywara's approach):

1. Clone mainline U-Boot
2. Apply Kconfig patch to add `CONFIG_SUNXI_ARMV8_32BIT_BUILD`
3. Create custom defconfig for Orange Pi 3 (32-bit, LPDDR3)
4. Build with `ARCH=arm CROSS_COMPILE=arm-linux-gnueabihf-`
5. The RMR switch is automatically skipped (boot0.h only includes the
   switch code when `CONFIG_ARM_BOOT_HOOK_RMR` is set, which requires ARM64)
6. Output: `u-boot-sunxi-with-spl.bin` containing 32-bit SPL + 32-bit U-Boot

**Advantages:**
- No proprietary blobs
- DRAM init code is proven (same code used by 64-bit builds)
- SPL naturally stays in AArch32 (no RMR switch needed)
- U-Boot proper built for ARM32 (full bootm/bootz support)

**Risks:**
- The Kconfig patches were never merged upstream (maintenance burden)
- 32-bit SD boot path less tested than FEL (Andre's patches focused on FEL)
- Some H6-specific U-Boot features may assume ARM64

---

## 3. 32-bit Linux Kernel for H6

### 3.1 Current State in Mainline

**arch/arm/mach-sunxi (32-bit) supports:**
- sun4i (A10), sun5i (A10s/A13), sun6i (A31), sun7i (A20)
- sun8i (A23/A33/H2+/H3/R40/A83T/V3s)
- suniv (F-series)

**No sun50i support whatsoever in the 32-bit ARM kernel tree.**

The H6 DTS lives at `arch/arm64/boot/dts/allwinner/sun50i-h6.dtsi` and
`sun50i-h6-orangepi-3.dts` (arm64 only).

### 3.2 Cortex-A53 AArch32 Kernel Compatibility

The Cortex-A53 implements ARMv8-A and supports AArch32 at ALL exception levels
(EL0, EL1, EL2, EL3). Running a 32-bit kernel at EL1 is architecturally valid.

The CPU will execute ARMv7-compatible (actually ARMv8 AArch32) instructions.
It supports VFPv3/v4 and NEON, compatible with armhf userspace.

### 3.3 What Needs Porting

#### Device Tree

Port `sun50i-h6.dtsi` and `sun50i-h6-orangepi-3.dts` from
`arch/arm64/boot/dts/allwinner/` to `arch/arm/boot/dts/allwinner/`.

Changes needed:
- **Interrupt controller:** H6 uses GICv2 (`arm,gic-400`), same as 32-bit
  sunxi SoCs. The DTS bindings are identical.
- **Timer:** Uses `arm,armv8-timer` — needs changing to `arm,armv7-timer`
  (same hardware, different compatible string for 32-bit kernel)
- **PSCI:** May need adjustment for 32-bit calling convention (SMC32 vs SMC64).
  Since we're not running TF-A, we skip PSCI entirely — CPUs start in AArch32
  SVC mode. SMP bringup uses the sunxi-specific method.
- **CPU nodes:** Change from `arm,cortex-a53` to include 32-bit compatible
  (the kernel's 32-bit code recognizes A53 in AArch32 mode)

#### Machine Support

Add `"allwinner,sun50i-h6"` to the compatible list in
`arch/arm/mach-sunxi/sunxi.c` so the kernel recognizes the SoC.

#### Clock Controller (CCU)

The H6 CCU driver (`drivers/clk/sunxi-ng/ccu-sun50i-h6.c`) is in the common
driver tree, NOT in arch/arm64. It should compile for ARM32 without changes.
CONFIG: `CONFIG_SUN50I_H6_CCU`

#### Other Drivers (All Architecture-Neutral)

| Peripheral | Driver | Config |
|------------|--------|--------|
| UART | 8250/DesignWare | `CONFIG_SERIAL_8250_DW` |
| MMC | sunxi-mmc | `CONFIG_MMC_SUNXI` |
| Ethernet | dwmac-sun8i | `CONFIG_DWMAC_SUN8I` |
| USB 2.0 | EHCI/OHCI sunxi | `CONFIG_USB_EHCI_HCD` |
| USB 3.0 | PHY sun50i | `CONFIG_PHY_SUN50I_USB3` |
| GPIO/Pinctrl | sun50i-h6 | `CONFIG_PINCTRL_SUN50I_H6` |
| Thermal | sun50i-h6-ths | `CONFIG_SUN50I_H6_THS` |
| PMIC | AXP805 via RSB | `CONFIG_MFD_AXP20X_RSB` |
| I2C/RSB | sunxi-rsb | `CONFIG_SUNXI_RSB` |

All these drivers live in `drivers/` (not `arch/arm64/`) and use standard
Linux driver APIs. They should compile for ARM32.

### 3.4 SMP Bringup (No TF-A)

Without TF-A, we cannot use PSCI for SMP bringup. Options:

1. **Sunxi SMP method:** The kernel's `arch/arm/mach-sunxi/` has SMP support
   for sun8i/sun9i using mailbox/software-initiated CPU power-on. The H6 likely
   uses a similar mechanism (CPUCFG registers). This needs investigation.

2. **Single-core initially:** Boot single-core first, add SMP later. This is
   the pragmatic approach — get the system running, then tackle SMP.

3. **Minimal AArch32 PSCI shim:** Write a tiny PSCI implementation in the SPL
   or a resident monitor that handles CPU_ON. Much simpler than full TF-A.

**Recommendation:** Start single-core. The H6 has 4x A53 cores but a single
core is sufficient for initial bring-up and testing.

### 3.5 Kernel Build Approach

1. Start from `multi_v7_defconfig` (includes broad sunxi support)
2. Add ported H6 DTS to `arch/arm/boot/dts/allwinner/`
3. Add H6 compatible string to `arch/arm/mach-sunxi/sunxi.c`
4. Enable H6-specific drivers (CCU, pinctrl, thermal)
5. Build with `ARCH=arm CROSS_COMPILE=arm-linux-gnueabihf-`

---

## 4. Feasibility Assessment

### What's Proven

- H6 DRAM init works in AArch32 (Andre's FEL patches, hexdump0815's libdram)
- Cortex-A53 runs AArch32 code at all exception levels
- All H6 peripheral drivers are architecture-neutral
- The eGON boot header works identically for 32-bit SPL

### What's Unproven / Risky

| Risk | Severity | Mitigation |
|------|----------|------------|
| U-Boot Kconfig patches may not apply cleanly to latest version | Medium | Pin to known working U-Boot version (v2024.01), adapt patches |
| 32-bit U-Boot proper for H6 untested | Medium | Andre's patches only built SPL; U-Boot proper needs CONFIG adjustments |
| H6 DTS port to 32-bit kernel | Medium | Mechanical work; same hardware, different compatible strings |
| SMP without TF-A | High | Start single-core; SMP bringup can follow |
| H6 CCU driver may have 64-bit assumptions | Low | Driver uses standard 32-bit MMIO; unlikely to have issues |
| SD card boot timing | Low | Same BROM, same SD controller, same protocol |

### Overall Assessment

**This is feasible but requires kernel porting work.** The U-Boot side is
well-understood from prior art. The kernel DTS port is mechanical. The main
unknown is SMP bringup without TF-A.

For a minimal boot-to-shell, single-core is fine. Getting all 4 cores requires
either porting the sunxi SMP code for H6 or writing a minimal PSCI shim.

---

## 5. Sources

- [U-Boot mainline dram_sun50i_h6.c](https://github.com/u-boot/u-boot/blob/master/arch/arm/mach-sunxi/dram_sun50i_h6.c)
- [U-Boot mach-sunxi Kconfig](https://github.com/u-boot/u-boot/blob/master/arch/arm/mach-sunxi/Kconfig)
- [Andre Przywara's H6 32-bit SPL patch](https://patchwork.ozlabs.org/project/uboot/patch/20190221013034.9099-10-andre.przywara@arm.com/)
- [Andre's FEL 32-bit patch series](https://groups.google.com/g/linux-sunxi/c/nSnc50BsFew)
- [apritzel/u-boot sunxi64-fel32 branch](https://github.com/apritzel/u-boot/commits/sunxi64-fel32)
- [hexdump0815 H6 libdram notes](https://github.com/hexdump0815/u-boot-misc/blob/master/readme.h6-libdram)
- [smaeul/sunxi-blobs repository](https://github.com/smaeul/sunxi-blobs)
- [Linux kernel ARM sunxi documentation](https://docs.kernel.org/arch/arm/sunxi.html)
- [Armbian forum: 32-bit on H6](https://forum.armbian.com/topic/15010-32-bit-armbian-on-orangepi-allwinner-h6-boards/)
- [linux-sunxi.org H6 page](https://linux-sunxi.org/H6)
