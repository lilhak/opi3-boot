# Makefile for AArch64→AArch32 trampoline
#
# Produces a flat binary (trampoline.bin) suitable for loading
# by U-Boot via "go" command.
#
# Usage:
#   make                    # build with aarch64-linux-gnu- toolchain
#   make CROSS_COMPILE=...  # override toolchain prefix
#   make clean

CROSS_COMPILE ?= aarch64-linux-gnu-
AS      = $(CROSS_COMPILE)as
LD      = $(CROSS_COMPILE)ld
OBJCOPY = $(CROSS_COMPILE)objcopy
OBJDUMP = $(CROSS_COMPILE)objdump

# Trampoline is loaded at this address by U-Boot
LOAD_ADDR = 0x40200000

TARGET  = trampoline
ASFLAGS =
LDFLAGS = -Ttext $(LOAD_ADDR) --no-dynamic-linker

all: $(TARGET).bin

$(TARGET).o: $(TARGET).S
	$(AS) $(ASFLAGS) -o $@ $<

$(TARGET).elf: $(TARGET).o
	$(LD) $(LDFLAGS) -o $@ $<

$(TARGET).bin: $(TARGET).elf
	$(OBJCOPY) -O binary $< $@
	@echo "Built $(TARGET).bin (load at $(LOAD_ADDR))"
	@echo "Size: $$(stat -f%z $@ 2>/dev/null || stat -c%s $@) bytes"

# Optional disassembly for verification
disasm: $(TARGET).elf
	$(OBJDUMP) -d $<

clean:
	rm -f $(TARGET).o $(TARGET).elf $(TARGET).bin

.PHONY: all clean disasm
