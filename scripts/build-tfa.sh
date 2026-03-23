#!/bin/bash
# Build ARM Trusted Firmware (BL31) for Allwinner H6
set -euo pipefail

WORK="${WORK:-$HOME/opi3-build}"
TFA_VERSION="${TFA_VERSION:-v2.10.0}"
TFA_DIR="$WORK/sources/tfa"

echo "=== Building TF-A $TFA_VERSION for sun50i_h6 ==="

mkdir -p "$WORK/sources"

if [ ! -d "$TFA_DIR" ]; then
    echo "Cloning TF-A..."
    git clone --depth 1 --branch "$TFA_VERSION" \
        https://git.trustedfirmware.org/TF-A/trusted-firmware-a.git "$TFA_DIR"
else
    echo "TF-A source already present at $TFA_DIR"
fi

cd "$TFA_DIR"
make CROSS_COMPILE=aarch64-linux-gnu- PLAT=sun50i_h6 bl31 -j"$(nproc)"

BL31="$TFA_DIR/build/sun50i_h6/release/bl31.bin"
if [ ! -f "$BL31" ]; then
    echo "ERROR: bl31.bin not found at $BL31"
    exit 1
fi

echo "=== TF-A build complete ==="
echo "BL31: $BL31"
echo ""
echo "Export for U-Boot build:"
echo "  export BL31=$BL31"
