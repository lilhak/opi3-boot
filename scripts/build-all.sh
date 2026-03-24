#!/bin/bash
# Master build script for Orange Pi 3 LTS boot SD card
set -euo pipefail

export WORK="${WORK:-$HOME/opi3-build}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "============================================"
echo "  Orange Pi 3 LTS - Full Build"
echo "============================================"
echo "  Workspace: $WORK"
echo "  Scripts:   $SCRIPT_DIR"
echo "============================================"
echo ""

mkdir -p "$WORK"/{sources,output,rootfs,mnt}

# Step 1: Build TF-A
echo ""
echo ">>> Step 1/5: Building TF-A..."
bash "$SCRIPT_DIR/build-tfa.sh"
export BL31="$WORK/sources/tfa/build/sun50i_h6/release/bl31.bin"

# Step 2: Build U-Boot
echo ""
echo ">>> Step 2/5: Building U-Boot..."
bash "$SCRIPT_DIR/build-uboot.sh"

# Step 3: Build kernel
echo ""
echo ">>> Step 3/5: Building kernel..."
bash "$SCRIPT_DIR/build-kernel.sh"

# Step 4: Create rootfs (requires root)
echo ""
echo ">>> Step 4/5: Creating rootfs..."
if [ "$(id -u)" -eq 0 ]; then
    bash "$SCRIPT_DIR/create-rootfs.sh"
else
    echo "Rootfs creation requires root. Running with sudo..."
    sudo WORK="$WORK" bash "$SCRIPT_DIR/create-rootfs.sh"
fi

# Step 5: Generate boot.scr
echo ""
echo ">>> Step 5/5: Generating boot.scr..."
DTB_NAME=$(cat "$WORK/output/dtb-name.txt" 2>/dev/null || echo "sun50i-h6-orangepi-3.dtb")

cat > "$WORK/output/boot.cmd" << BOOTCMD
setenv bootargs console=ttyS0,115200 earlycon=uart8250,mmio32,0x05000000 root=LABEL=rootfs rootfstype=ext4 rootwait rw panic=10 loglevel=7
if load mmc 0:1 \${kernel_addr_r} /boot/Image; then
  load mmc 0:1 \${fdt_addr_r} /boot/allwinner/$DTB_NAME
else
  load mmc 1:1 \${kernel_addr_r} /boot/Image
  load mmc 1:1 \${fdt_addr_r} /boot/allwinner/$DTB_NAME
fi
booti \${kernel_addr_r} - \${fdt_addr_r}
BOOTCMD

mkimage -C none -A arm64 -T script -d "$WORK/output/boot.cmd" "$WORK/output/boot.scr"

echo ""
echo "============================================"
echo "  Build complete!"
echo "============================================"
echo ""
echo "To write to SD card:"
echo "  sudo $SCRIPT_DIR/assemble-sd.sh /dev/sdX"
echo ""
echo "Build outputs in: $WORK/output/"
ls -la "$WORK/output/"
