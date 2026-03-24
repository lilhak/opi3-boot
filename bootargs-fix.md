# Boot Arguments Analysis & Fix for Orange Pi 3 LTS ARM32

## Analysis of Ralph's Boot Log (2026-03-24)

### What Worked:
✅ **mmio32 fix successful**: `earlycon=uart8250,mmio32,0x05000000` now works
✅ **Kernel loads**: Linux 6.6.70-dirty boots correctly
✅ **Memory detection**: 2GB RAM detected properly
✅ **Pinctrl working**: Pin controller initializes successfully 
✅ **Serial detected**: UART at MMIO 0x5000000 (irq = 245) is a 16550A

### The Problem:
The boot **hangs at console handoff** after this line:
```
[    6.726699] printk: console [ttyS0] enabled
```

The UTF-8 replacement character (0xef 0xbf 0xbd = "�") suggests console corruption during the handoff from earlycon to regular console.

### Root Cause:
Console handoff issue between:
1. Early console (`earlycon=uart8250,mmio32,0x05000000`)  
2. Regular console (`console=ttyS0,115200`)
3. Boot console preservation (`keep_bootcon`)

The `keep_bootcon` parameter is meant to prevent early console from being disabled, but it can cause conflicts when the regular console initializes.

## Fix Strategy

### Option 1: Remove keep_bootcon (Primary Fix)
```bash
setenv bootargs console=ttyS0,115200 earlycon=uart8250,mmio32,0x05000000 ignore_loglevel root=/dev/mmcblk0p1 rootwait rw panic=10 loglevel=8
```
**Changes:**
- ✅ Keep `earlycon=uart8250,mmio32,0x05000000` (this fixed the initial issue)
- ❌ Remove `keep_bootcon` (prevents handoff conflicts)
- ❌ Remove `earlyprintk=ttyS0,115200` (redundant with earlycon)

### Option 2: Explicit Console Handoff (Fallback)
```bash
setenv bootargs console=ttyS0,115200 earlycon=uart8250,mmio32,0x05000000 ignore_loglevel root=/dev/mmcblk0p1 rootwait rw panic=10 loglevel=8 console_suspend=n
```
Add `console_suspend=n` to prevent console suspension during handoff.

### Option 3: Force Early Console Only (Debug)
```bash  
setenv bootargs earlycon=uart8250,mmio32,0x05000000 ignore_loglevel keep_bootcon root=/dev/mmcblk0p1 rootwait rw panic=10 loglevel=8
```
Remove regular console entirely, rely only on earlycon.

## CRITICAL UPDATE (2026-03-24 04:08 AM)

Ralph tried the bootargs but used `mmio` instead of `mmio32` in earlycon:
- Used: `earlycon=uart8250,mmio,0x05000000` ❌
- Should be: `earlycon=uart8250,mmio32,0x05000000` ✅

Result: Boot output reduced to single '[' character - complete early console failure.

**ROOT CAUSE:** `mmio` parameter doesn't work on ARM32 systems. Must use `mmio32` for 32-bit register access.

## Recommendation for Ralph

**EXACT bootargs to use** (mmio32 is critical):
```bash
setenv bootargs console=ttyS0,115200 earlycon=uart8250,mmio32,0x05000000 ignore_loglevel root=/dev/mmcblk0p1 rootwait rw panic=10 loglevel=8
load mmc 0:1 0x42000000 /boot/zImage
load mmc 0:1 0x44000000 /boot/sun50i-h6-orangepi-3.dtb
bootz 0x42000000 - 0x44000000
```

This should allow:
1. Early console to work during boot (✅ already working)
2. Clean handoff to regular ttyS0 console
3. System to continue booting past serial initialization
4. Eventually reach MMC/rootfs mounting and login prompt

## Expected Next Steps

If this fix works, Ralph should see:
1. All the current boot output (up to console handoff)
2. **Continued boot progression** past `printk: console [ttyS0] enabled`
3. MMC controller initialization
4. Root filesystem detection and mounting
5. Init system startup
6. Eventually: login prompt

The SMP issue (secondary CPUs failing) is separate and can be addressed later if needed.