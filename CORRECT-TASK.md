# CORRECT TASK: Native AArch32 Boot Chain for Orange Pi 3 LTS

## Key Insight (Confirmed via Research)
ALL Allwinner ARMv8 SoCs (A64, H5, H6) cold-reset into AArch32. The BROM is AArch32.
The current U-Boot SPL contains an RMR switch (`arch/arm/mach-sunxi/rmr_switch.S`)
that triggers a warm reset into AArch64. This is the ONLY reason the system ends up
in 64-bit mode.

**If we skip the RMR switch, the system stays in AArch32 natively.**

## Proof
From `u-boot/arch/arm/mach-sunxi/rmr_switch.S`:
```
@ All 64-bit capable Allwinner SoCs reset in AArch32 (and continue to
@ execute the Boot ROM in this state), so we need to switch to AArch64
@ at some point.
```

From `u-boot/board/sunxi/README.sunxi64`:
```
Both U-Boot proper and the SPL are using the 64-bit mode. As the boot ROM
enters the SPL still in AArch32 secure SVC mode, there is some shim code to
enter AArch64 very early.
```

## The Real Boot Chain We Need
```
Cold reset → AArch32
  → BROM loads SPL (AArch32) from SD @ 8KB
    → SPL initializes DRAM (AArch32)
      → SPL loads U-Boot proper (AArch32)
        → U-Boot loads 32-bit zImage + DTB
          → 32-bit Linux kernel boots
            → Devuan armhf userspace
```

No TF-A. No RMR. No warm reset. No trampoline. Just stay 32-bit.

## What Must Be Built

### 1. U-Boot SPL (AArch32) for H6
The challenge: mainline U-Boot's sunxi64 code assumes AArch64 SPL. We need either:

**Option A: Build U-Boot with ARCH=arm for sun50i_h6**
- Check if `configs/orangepi_3_defconfig` or similar can be adapted for 32-bit build
- The H6 DRAM controller init may exist in 32-bit sunxi code (check arch/arm/mach-sunxi/dram_*)
- Key question: does `dram_sun50i_h6.c` exist and work in 32-bit mode?

**Option B: Use Allwinner's boot0/boot1 as the 32-bit SPL**
- Allwinner's original boot0 is AArch32 and initializes DRAM
- Smaeul's sunxi-blobs repo has extracted BROM/boot0 binaries
- boot0 does DRAM init and loads the next stage from SD card
- This avoids all U-Boot SPL porting work for DRAM init

**Option C: Hybrid approach**
- Use 32-bit boot0 for DRAM init (proven to work on H6 in AArch32)
- Then load a 32-bit U-Boot proper for the boot menu/kernel loading
- boot0 → U-Boot proper (32-bit) → zImage

Research which option is viable. Check:
1. Does mainline U-Boot have dram_sun50i_h6.c that works in 32-bit compilation?
2. Are there Allwinner boot0 blobs available for H6?
3. Has anyone built a 32-bit U-Boot for any sun50i SoC?

### 2. U-Boot Proper (AArch32)
- Must support: MMC read, ext4 filesystem, DTB loading, zImage boot
- Should be straightforward ARM32 U-Boot build if SPL is solved
- Need a defconfig that enables H6 MMC, UART, and basic peripherals

### 3. 32-bit Kernel for H6
Options:
- Port sun50i-h6 DTS to arch/arm/boot/dts/
- Add minimal MACH_SUN50I support to arch/arm/mach-sunxi/
- Use Armbian or vendor kernel if one exists with 32-bit H6 support
- The peripheral IP blocks (UART, MMC, EMAC) are likely the same as other sunxi SoCs

### 4. Build Scripts
- Remove the trampoline (it was the wrong approach)
- `scripts/build-uboot-arm32.sh` - Builds 32-bit U-Boot
- `scripts/build-kernel-arm32.sh` - Builds 32-bit kernel
- Updated `scripts/assemble-sd.sh` for 32-bit layout
- `BUILD-GUIDE-32BIT.md` - Complete guide

### 5. SD Card Layout for AArch32
```
Offset          Content
0x0000          MBR
0x2000 (8KB)    U-Boot SPL (AArch32) with eGON header
0x100000 (1MB)  Partition 1 (ext4)
                ├── /boot/zImage
                ├── /boot/sun50i-h6-orangepi-3.dtb
                ├── /boot/boot.scr
                └── rootfs...
```

## Critical Research Questions
1. **H6 DRAM init in 32-bit mode** - This is the hardest problem. The DRAM controller
   code for H6 may only exist in the AArch64 SPL path. If so, we need boot0.
2. **H6 peripherals in 32-bit kernel** - Which existing sunxi drivers work?
   The H6 uses sun50i clock gates, PHYs, etc. Some may need porting.
3. **boot0 availability** - Check https://github.com/smaeul/sunxi-blobs for H6 boot0.

## Output Files
- `BUILD-GUIDE-32BIT.md` - Complete updated guide
- `scripts/build-uboot-arm32.sh`
- `scripts/build-kernel-arm32.sh`
- `scripts/assemble-sd-arm32.sh`
- `docs/h6-32bit-research.md` - Research findings on DRAM init, boot0, etc.
- Remove or archive the trampoline directory

## Constraints
- Must be concrete and buildable
- Research the actual U-Boot and kernel source to determine feasibility
- Don't guess - look at the code
