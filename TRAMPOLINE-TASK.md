# REAL TASK: Native 32-bit Kernel Boot on Orange Pi 3 LTS (Allwinner H6)

## Problem Statement
The H6 BROM boots in AArch64. Standard TF-A + U-Boot run in AArch64. The current boot chain switches to 64-bit and stays there. We need to boot a TRUE 32-bit ARM kernel (not arm64 + armhf compat).

The system currently works in a 64-bit emulator running 32-bit userspace. The goal is NATIVE 32-bit kernel execution on real hardware.

## Architecture Constraint
- Cortex-A53 supports AArch32 at ALL exception levels (EL0, EL1, EL2, EL3)
- AArch64 → AArch32 transition can ONLY happen via ERET to a LOWER exception level
- SCR_EL3.RW bit controls AArch64 vs AArch32 for EL2 and below
- HCR_EL2.RW bit controls AArch64 vs AArch32 for EL1

## Required Approach: AArch64-to-AArch32 Trampoline

### Boot chain:
```
BROM (AArch64, immutable)
  → U-Boot SPL (AArch64)
    → TF-A BL31 (AArch64, EL3)
      → U-Boot proper (AArch64, EL2)
        → Trampoline (AArch64, loaded by U-Boot as "kernel")
          → Sets HCR_EL2.RW=0 (force AArch32 at EL1)
          → Sets SPSR_EL2 for AArch32 SVC mode
          → Sets ELR_EL2 to 32-bit zImage entry
          → ERET
            → 32-bit Linux kernel (AArch32, EL1, SVC mode) ← THIS IS THE GOAL
```

## What You Must Build

### 1. AArch64→AArch32 Trampoline (`trampoline/`)
- Small AArch64 assembly program (~50-100 instructions)
- Loaded by U-Boot at a known address via `booti` or raw `go` command
- Receives: r0/x0 = DTB address, knows where zImage is in memory
- Does:
  1. Disable MMU, caches (ensure clean state)
  2. Set HCR_EL2.RW = 0 (AArch32 for EL1)  
  3. Set SPSR_EL2 = AArch32 SVC mode, interrupts masked (0x1d3)
  4. Set ELR_EL2 = address of zImage in memory
  5. Pass DTB pointer in r2 (ARM boot protocol: r0=0, r1=machine_id, r2=DTB)
  6. ERET to EL1 → now executing AArch32
- Must handle: cache/TLB invalidation, barrier instructions
- Build with aarch64-linux-gnu-as, produce a flat binary
- Must also handle the case where we arrive at EL1 already (need to check CurrentEL)
- If at EL1 in AArch64, we need TF-A to do the switch (modify PSCI or use SMC)

### 2. 32-bit Kernel Build Strategy
The H6 has NO device trees under arch/arm/. Options (pick the best):

**Option A: Use arm64 DTB with 32-bit kernel**
- The DTB format is architecture-independent
- 32-bit kernel can parse arm64-originated DTBs if compatible strings match
- Need to verify sunxi 32-bit drivers can handle H6 peripherals

**Option B: Port the DTS to arch/arm/**  
- Copy sun50i-h6-orangepi-3.dts adaptations into arch/arm/boot/dts/
- Add MACH_SUN50I or equivalent to arch/arm/mach-sunxi
- More correct but more work

**Option C: Use a vendor/Armbian 32-bit kernel if one exists**
- Research whether any BSP ships a 32-bit H6 kernel
- Least work if it exists

Choose the option most likely to produce a booting kernel. Document your choice.

### 3. Modified Boot Scripts
- New `boot.cmd` / `boot.scr` that:
  - Loads the trampoline binary to a safe address
  - Loads the 32-bit zImage to another address  
  - Loads DTB
  - Jumps to trampoline via `go` command (not `booti` which expects arm64 Image)
- Memory map must not overlap

### 4. SMP Consideration
- For SMP on AArch32, secondary CPUs need PSCI to also switch them to AArch32
- TF-A's PSCI cpu_on handler may need modification to set SCR_EL3.RW=0 for secondaries
- Document whether stock TF-A sun50i_h6 PSCI supports AArch32 secondary boot
- If not, provide the TF-A patch

### 5. Kernel Config for 32-bit H6
```
CONFIG_SMP=y
CONFIG_ARCH_SUNXI=y (or ARCH_SUN50I if it exists in 32-bit tree)
CONFIG_ARM_LPAE=y (for >4GB address space if needed, H6 has addresses above 4GB)
CONFIG_VFPv3=y
CONFIG_NEON=y
```

## Output Files
Create these in the repo:
- `trampoline/trampoline.S` - The AArch64 assembly trampoline
- `trampoline/Makefile` - Builds the flat binary
- `trampoline/README.md` - Explains the mode switch mechanism
- `scripts/build-kernel-arm32.sh` - Builds the 32-bit kernel
- `BUILD-GUIDE-32BIT.md` - Updated guide for the native 32-bit approach
- Any TF-A patches needed in `patches/tfa/`
- Updated `boot.cmd` for the trampoline flow

## Research First
Before writing code:
1. Check if TF-A sun50i_h6 PSCI already supports AArch32 secondary CPU boot
2. Check if any 32-bit kernel config includes H6/sun50i support
3. Check the exact EL state U-Boot hands off to the "kernel" (EL2? EL1?)
4. Check ARM ARM for exact register values needed for AArch64→AArch32 ERET

## Constraints
- Must produce runnable code, not pseudocode
- Assembly must be correct ARM AArch64 syntax (GNU as)
- All memory addresses must be explicitly chosen and documented
- Handle edge cases: what if we're at EL1 not EL2? What if caches are dirty?
