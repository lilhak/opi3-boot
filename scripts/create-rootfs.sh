#!/bin/bash
# Create Devuan Daedalus armhf rootfs via debootstrap
set -euo pipefail

WORK="${WORK:-$HOME/opi3-build}"
ROOTFS="$WORK/rootfs"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "=== Creating Devuan Daedalus armhf rootfs ==="

# Check we're root
if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: This script must be run as root (or via sudo)"
    exit 1
fi

mkdir -p "$ROOTFS"

# Ensure debootstrap knows about daedalus
if [ ! -f /usr/share/debootstrap/scripts/daedalus ]; then
    echo "Creating daedalus debootstrap script symlink..."
    ln -sf sid /usr/share/debootstrap/scripts/daedalus
fi

# Install devuan-keyring if not present
if ! dpkg -l devuan-keyring >/dev/null 2>&1; then
    echo "Installing devuan-keyring..."
    KEYRING_DEB=$(mktemp /tmp/devuan-keyring-XXXXXX.deb)
    wget -O "$KEYRING_DEB" \
        http://deb.devuan.org/devuan/pool/main/d/devuan-keyring/devuan-keyring_2023.05.20_all.deb || true
    if [ -f "$KEYRING_DEB" ] && [ -s "$KEYRING_DEB" ]; then
        dpkg -i "$KEYRING_DEB"
        rm -f "$KEYRING_DEB"
    else
        echo "WARNING: Could not fetch devuan-keyring, trying --no-check-gpg"
        DEBOOTSTRAP_EXTRA="--no-check-gpg"
    fi
fi

# First stage debootstrap
echo "Running first-stage debootstrap..."
debootstrap --arch=armhf --foreign --variant=minbase \
    ${DEBOOTSTRAP_EXTRA:-} \
    --include=sysvinit-core,sysv-rc,eudev,kmod,iproute2,ifupdown,isc-dhcp-client,openssh-server,procps,nano,wget,ca-certificates,locales,apt-transport-https,dialog,less \
    daedalus "$ROOTFS" http://deb.devuan.org/merged/

# Copy QEMU for ARM emulation in chroot
if [ -f /usr/bin/qemu-arm-static ]; then
    cp /usr/bin/qemu-arm-static "$ROOTFS/usr/bin/"
else
    echo "ERROR: /usr/bin/qemu-arm-static not found"
    echo "Install: apt install qemu-user-static binfmt-support"
    exit 1
fi

# Second stage
echo "Running second-stage debootstrap..."
chroot "$ROOTFS" /debootstrap/debootstrap --second-stage

# Configure rootfs
echo "Configuring rootfs..."
cp "$SCRIPT_DIR/configure-rootfs.sh" "$ROOTFS/tmp/"
chroot "$ROOTFS" /bin/bash /tmp/configure-rootfs.sh

# Install kernel modules if available
KERNEL_DIR="$WORK/sources/linux"
if [ -d "$KERNEL_DIR" ] && [ -f "$KERNEL_DIR/.config" ]; then
    echo "Installing kernel modules..."
    cd "$KERNEL_DIR"
    make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- \
        INSTALL_MOD_PATH="$ROOTFS" modules_install
fi

# Clean up QEMU binary (not needed on target)
rm -f "$ROOTFS/usr/bin/qemu-arm-static"

echo "=== Rootfs creation complete ==="
echo "Root filesystem: $ROOTFS"
