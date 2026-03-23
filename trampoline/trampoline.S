/*
 * trampoline.S — AArch64-to-AArch32 mode switch trampoline
 *
 * Loaded by U-Boot at 0x40200000 via "go 0x40200000".
 * Switches the CPU from AArch64 EL2 to AArch32 EL1 (SVC mode)
 * and jumps to a 32-bit zImage.
 *
 * Entry contract (from U-Boot "go" command):
 *   x0 = DTB address (0x48000000)
 *   x1 = zImage address (0x42000000), or use hardcoded default
 *
 * Exit contract (ARM 32-bit boot protocol):
 *   r0 = 0
 *   r1 = 0xFFFFFFFF (no machine ID; DTB-only boot)
 *   r2 = DTB physical address
 *   PC = zImage entry point
 *   Mode = AArch32 SVC, IRQ/FIQ/Abort masked
 *
 * Memory layout:
 *   0x40200000  this trampoline
 *   0x42000000  zImage
 *   0x48000000  DTB
 *
 * References:
 *   ARM ARM DDI 0487 — D1.6 (ERET), D12.2.47 (HCR_EL2),
 *   G8.2.155 (SPSR_EL2), C5.2.19 (SCTLR_EL2)
 */

        .section .text, "ax"
        .globl  _start
        .align  4               /* 16-byte alignment for entry */

/* ----------------------------------------------------------------
 * Default addresses — may be overridden by x0/x1 from U-Boot
 * ---------------------------------------------------------------- */
.equ ZIMAGE_ADDR,       0x42000000
.equ DTB_ADDR,          0x48000000

/* ----------------------------------------------------------------
 * SPSR_EL2 value for AArch32 SVC mode, all exceptions masked
 *
 *   Bit [4]   = 0  → target state is AArch32 (T32/A32 determined by bit 5)
 *   Bits[3:0] = 0011 → SVC mode (0b10011, but bit4=0 so M[4:0]=0x13)
 *
 *   Actually encoded as SPSR_EL2 = 0x1d3:
 *     M[4:0] = 10011  (SVC)       bits [4:0]  = 0x13
 *     T      = 0      (ARM state) bit  [5]    = 0
 *     F      = 1      (FIQ mask)  bit  [6]    = 1
 *     I      = 1      (IRQ mask)  bit  [7]    = 1
 *     A      = 1      (SError)    bit  [8]    = 1
 *     D      = 0                  bit  [9]    = 0
 *   → 0x1d3 = 0b 1 1101 0011
 * ---------------------------------------------------------------- */
.equ SPSR_EL2_AARCH32_SVC, 0x1d3

_start:
        /* --------------------------------------------------------
         * Save arguments: x0=DTB, x1=zImage (optional)
         * Use callee-saved registers to keep them across operations
         * -------------------------------------------------------- */
        mov     x19, x0                /* x19 = DTB address */
        cbz     x1, .Luse_default_zimage
        mov     x20, x1                /* x20 = zImage address from caller */
        b       .Lcheck_el
.Luse_default_zimage:
        ldr     x20, =ZIMAGE_ADDR      /* x20 = hardcoded zImage address */

        /* --------------------------------------------------------
         * Step 1: Determine current exception level
         * -------------------------------------------------------- */
.Lcheck_el:
        mrs     x2, CurrentEL
        lsr     x2, x2, #2             /* extract EL field (bits [3:2]) */
        cmp     x2, #2
        b.eq    .Lat_el2
        cmp     x2, #1
        b.eq    .Lat_el1

        /* If we're at EL3, something is very wrong — spin */
        b       .Lhang

        /* --------------------------------------------------------
         * EL1 path: we cannot set HCR_EL2 from EL1.
         * This requires TF-A cooperation via SMC.  Hang for now.
         * -------------------------------------------------------- */
.Lat_el1:
        b       .Lhang

        /* --------------------------------------------------------
         * Step 2: We are at EL2 — disable MMU and caches
         * -------------------------------------------------------- */
.Lat_el2:
        /* 2a. Disable EL2 MMU, D-cache, I-cache */
        mrs     x2, sctlr_el2
        bic     x2, x2, #(1 << 0)     /* M  — MMU off */
        bic     x2, x2, #(1 << 2)     /* C  — D-cache off */
        bic     x2, x2, #(1 << 12)    /* I  — I-cache off */
        msr     sctlr_el2, x2
        isb

        /* 2b. Also ensure EL1 MMU/caches are off for the new world */
        mrs     x2, sctlr_el1
        bic     x2, x2, #(1 << 0)     /* M  — MMU off */
        bic     x2, x2, #(1 << 2)     /* C  — D-cache off */
        bic     x2, x2, #(1 << 12)    /* I  — I-cache off */
        bic     x2, x2, #(1 << 19)    /* WXN off */
        msr     sctlr_el1, x2
        isb

        /* --------------------------------------------------------
         * Step 3: Clean and invalidate data caches, invalidate TLBs
         * -------------------------------------------------------- */

        /* Invalidate all TLB entries at EL1 and EL2 */
        tlbi    alle2
        tlbi    alle1
        dsb     sy
        isb

        /* Invalidate I-cache to point-of-unification */
        ic      iallu
        dsb     sy
        isb

        /* Clean + invalidate D-cache by set/way (all levels)
         *
         * We iterate each cache level reported by CLIDR_EL1,
         * performing DC CISW on each set/way.
         */
        mrs     x0, clidr_el1
        and     w3, w0, #0x07000000    /* extract LoC (Level of Coherence) */
        lsr     w3, w3, #23            /* LoC field starts at bit 24, ×2 = bit 23 */
        cbz     w3, .Ldc_done          /* if LoC == 0, no caches */

        mov     w10, #0                /* w10 = level × 2 (starts at 0) */
.Ldc_next_level:
        add     w12, w10, w10, lsr #1  /* w12 = level × 3 (index into ctype fields) */
        lsr     w6, w0, w12
        and     w6, w6, #7             /* cache type for this level */
        cmp     w6, #2
        b.lt    .Ldc_skip              /* no data/unified cache at this level */

        /* Select this cache level */
        msr     csselr_el1, x10
        isb

        mrs     x1, ccsidr_el1
        and     w2, w1, #7             /* LineSize field → log2(words)-2 */
        add     w2, w2, #4             /* w2 = log2(bytes per line) */
        ubfx    w4, w1, #3, #10        /* Associativity - 1 */
        clz     w5, w4                 /* bit position of way in DC op */
        ubfx    w7, w1, #13, #15       /* NumSets - 1 */

.Ldc_next_set:
        mov     w8, w4                 /* w8 = current way */
.Ldc_next_way:
        lsl     w9, w8, w5
        orr     w9, w10, w9            /* insert level */
        lsl     w11, w7, w2
        orr     w9, w9, w11            /* insert set */
        dc      cisw, x9               /* clean+invalidate by set/way */
        subs    w8, w8, #1
        b.ge    .Ldc_next_way
        subs    w7, w7, #1
        b.ge    .Ldc_next_set

.Ldc_skip:
        add     w10, w10, #2           /* next cache level */
        cmp     w10, w3
        b.lt    .Ldc_next_level

.Ldc_done:
        dsb     sy
        isb

        /* --------------------------------------------------------
         * Step 4: Configure HCR_EL2 — force AArch32 at EL1
         *
         * HCR_EL2.RW (bit 31): 0 = EL1 executes AArch32
         * Also clear other virtualisation bits we don't need.
         * -------------------------------------------------------- */
        mrs     x2, hcr_el2
        bic     x2, x2, #(1 << 31)    /* RW = 0 → AArch32 at EL1 */
        msr     hcr_el2, x2
        isb

        /* --------------------------------------------------------
         * Step 5: Set SPSR_EL2 for AArch32 SVC mode
         *
         *   0x1d3 = AArch32 SVC mode, IRQ/FIQ/Abort masked
         *   Bit [4] = 0 → ERET targets AArch32
         *   M[4:0]  = 10011 (SVC)
         *   F=1, I=1, A=1
         * -------------------------------------------------------- */
        ldr     x2, =SPSR_EL2_AARCH32_SVC
        msr     spsr_el2, x2
        isb

        /* --------------------------------------------------------
         * Step 6: Set ELR_EL2 = zImage entry point
         *
         * After ERET, PC will be set to this value.
         * -------------------------------------------------------- */
        msr     elr_el2, x20
        isb

        /* --------------------------------------------------------
         * Step 7: Set up AArch32 registers for Linux boot protocol
         *
         * After ERET to AArch32 EL1:
         *   r0 = 0
         *   r1 = machine ID (0xFFFFFFFF = use DTB)
         *   r2 = DTB physical address
         *
         * In AArch64, x0-x3 map to r0-r3 in AArch32:
         *   x0[31:0] → r0
         *   x1[31:0] → r1
         *   x2[31:0] → r2
         * -------------------------------------------------------- */
        mov     x0, #0                         /* r0 = 0 */
        mov     x1, #0xFFFFFFFF                /* r1 = no machine ID */
        and     x2, x19, #0xFFFFFFFF           /* r2 = DTB (32-bit) */
        mov     x3, #0                         /* r3 = 0 (unused) */

        /* --------------------------------------------------------
         * Step 8: ERET — enter AArch32 EL1 SVC mode
         *
         * CPU will:
         *   - Load PC from ELR_EL2
         *   - Load CPSR from SPSR_EL2
         *   - Switch to AArch32 state (SPSR_EL2[4]=0, HCR_EL2.RW=0)
         *   - Begin executing zImage at 0x42000000 in SVC mode
         * -------------------------------------------------------- */
        dsb     sy
        isb
        eret

        /* --------------------------------------------------------
         * Hang loop — reached on error (wrong EL, etc.)
         * -------------------------------------------------------- */
        .align  4
.Lhang:
        wfe
        b       .Lhang

        .end
