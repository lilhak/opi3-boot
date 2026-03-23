# AArch64→AArch32 Trampoline

## Purpose

This trampoline switches the Orange Pi 3 LTS (Allwinner H6, Cortex-A53) from AArch64 EL2 to AArch32 EL1, enabling a native 32-bit Linux kernel to boot on hardware that starts in 64-bit mode.

The H6's boot ROM, TF-A, and U-Boot all run in AArch64. The ARM architecture only allows a 64-to-32-bit switch via ERET to a lower exception level. This trampoline performs that switch.

## How It Works

```
U-Boot (AArch64, EL2)
  │
  │  go 0x40200000
  ▼
Trampoline entry (_start, AArch64 EL2)
  │
  ├─ 1. Verify we are at EL2
  ├─ 2. Disable MMU + caches (SCTLR_EL2, SCTLR_EL1)
  ├─ 3. Clean/invalidate D-cache by set/way, invalidate I-cache + TLBs
  ├─ 4. Set HCR_EL2.RW = 0  (EL1 will be AArch32)
  ├─ 5. Set SPSR_EL2 = 0x1d3 (AArch32 SVC, IRQ/FIQ/Abort masked)
  ├─ 6. Set ELR_EL2 = 0x42000000 (zImage entry)
  ├─ 7. Set x0=0, x1=0xFFFFFFFF, x2=DTB address
  │      (maps to r0, r1, r2 in AArch32)
  └─ 8. ERET
         │
         ▼
  zImage (AArch32, EL1, SVC mode)
    r0=0, r1=0xFFFFFFFF, r2=DTB pointer
```

## Key Register Settings

| Register     | Value        | Effect                                    |
|-------------|-------------|-------------------------------------------|
| HCR_EL2.RW  | 0 (bit 31)  | EL1 executes in AArch32 mode              |
| SPSR_EL2    | 0x1d3       | AArch32 SVC mode, DAIF masked             |
| ELR_EL2     | 0x42000000  | Execution resumes at zImage               |

### SPSR_EL2 breakdown (0x1d3)

```
Bit [4]    = 0     → target state is AArch32
Bits [3:0] = 0011  → with bit4, M[4:0] = 10011 = SVC mode
Bit [6]    = 1     → FIQ masked
Bit [7]    = 1     → IRQ masked
Bit [8]    = 1     → SError/Abort masked
```

## Memory Layout

| Address      | Contents              |
|-------------|----------------------|
| 0x40200000  | Trampoline (this binary) |
| 0x42000000  | 32-bit zImage         |
| 0x48000000  | Device tree blob (DTB) |

## Building

```bash
make                              # uses aarch64-linux-gnu- prefix
make CROSS_COMPILE=aarch64-none-elf-  # alternate toolchain
make disasm                       # view disassembly for verification
```

Produces `trampoline.bin`, a flat binary with no headers.

## Usage with U-Boot

```
# Load files to memory (from SD card, TFTP, etc.)
load mmc 0:1 0x40200000 trampoline.bin
load mmc 0:1 0x42000000 zImage
load mmc 0:1 0x48000000 sun50i-h6-orangepi-3-lts.dtb

# Jump to trampoline: x0=DTB, x1=zImage address
go 0x40200000 0x48000000 0x42000000
```

U-Boot's `go` command passes arguments in x0, x1, etc. The trampoline uses x0 as the DTB address and x1 as the zImage address (falls back to 0x42000000 if x1 is 0).

## Limitations

- **EL2 required**: The trampoline must be entered at EL2. If U-Boot drops to EL1 (non-standard), the trampoline will hang. An EL1 path would require an SMC call to TF-A.
- **Single core**: This trampoline switches only the executing CPU. Secondary cores require PSCI (`cpu_on`) to bring them up in AArch32 mode, which may need a TF-A patch to set SCR_EL3.RW=0.
- **No MMU**: The trampoline runs and exits with MMU disabled. The zImage decompressor sets up its own page tables.

## ARM Architecture References

- ARM ARM DDI 0487: D1.6 (Exception return), D12.2.47 (HCR_EL2), G8.2.155 (SPSR_EL2)
- HCR_EL2.RW (bit 31): controls execution state at EL1
- SPSR_EL2[4]=0: ERET targets AArch32 state
- AArch64 x0-x3 map to AArch32 r0-r3 on state transition
