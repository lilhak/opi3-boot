# Orange Pi 3 LTS ARM32 Boot Debug Log

## March 24, 2026 - CRITICAL BOOTARGS BUG FOUND

### Ralph's Report (02:34 AM)
- Tested bootargs with `keep_bootcon` as suggested
- Used: `earlycon=uart8250,mmio,0x05000000` 
- Result: Only single `[` character output, complete hang

### Root Cause Analysis
**CRITICAL BUG**: Ralph used `mmio` instead of `mmio32` for earlycon

The Allwinner H6 SoC requires 32-bit MMIO register access for UART:
- ❌ Wrong: `earlycon=uart8250,mmio,0x05000000`
- ✅ Correct: `earlycon=uart8250,mmio32,0x05000000`

### Fix Sent to Ralph (04:38 AM)
Updated bootargs with correct mmio32:
```
setenv bootargs console=ttyS0,115200 earlycon=uart8250,mmio32,0x05000000 earlyprintk=ttyS0,115200 ignore_loglevel keep_bootcon root=/dev/mmcblk0p1 rootwait rw panic=10 loglevel=8
```

This explains the immediate failure - without proper earlycon, we get no early boot output.

### Expected Outcome
With correct mmio32, we should see:
1. Early U-Boot output
2. Kernel decompression messages  
3. Early kernel boot messages via earlycon
4. Progress through pinctrl probing
5. Either console handoff issues (previous problem) OR further progress

### Status
- **Thread ID**: 19d1f30f1a1be247
- **Action**: Waiting for Ralph's test with corrected mmio32 bootargs
- **Learning**: Always double-check SoC-specific MMIO requirements

### Previous Known Threads
- 19d1f1b160f5348b - "same image with mmcblk0p1"
- 19d1ef968e53dd40 - (previous)
- 19d1e50e9eca2abc - (previous) 
- 19d1f2573faab421 - (previous)
- **19d1f30f1a1be247** - "testing revised bootargs" (NEW - mmio bug found)