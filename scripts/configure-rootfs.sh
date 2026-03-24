#!/bin/bash
# Configure Devuan Daedalus rootfs (runs INSIDE chroot)
set -euo pipefail

echo "=== Configuring Devuan Daedalus rootfs ==="

# --- APT sources ---
cat > /etc/apt/sources.list << 'EOF'
deb http://deb.devuan.org/merged/ daedalus main
deb http://deb.devuan.org/merged/ daedalus-updates main
deb http://deb.devuan.org/merged/ daedalus-security main
EOF

# --- fstab ---
cat > /etc/fstab << 'EOF'
LABEL=rootfs    /         ext4    defaults,noatime  0  1
tmpfs           /tmp      tmpfs   defaults          0  0
proc            /proc     proc    defaults          0  0
sysfs           /sys      sysfs   defaults          0  0
devpts          /dev/pts  devpts  defaults          0  0
EOF

# --- Hostname ---
echo "opi3lts" > /etc/hostname
cat > /etc/hosts << 'EOF'
127.0.0.1   localhost
127.0.1.1   opi3lts
::1         localhost ip6-localhost ip6-loopback
EOF

# --- Serial console getty ---
# Ensure inittab has serial console entry
if [ -f /etc/inittab ]; then
    if ! grep -q "ttyS0" /etc/inittab; then
        echo "T0:2345:respawn:/sbin/getty -L ttyS0 115200 vt100" >> /etc/inittab
    fi
else
    cat > /etc/inittab << 'INITTAB'
id:2:initdefault:
si::sysinit:/etc/init.d/rcS
~~:S:wait:/sbin/sulogin
l0:0:wait:/etc/init.d/rc 0
l1:1:wait:/etc/init.d/rc 1
l2:2:wait:/etc/init.d/rc 2
l3:3:wait:/etc/init.d/rc 3
l4:4:wait:/etc/init.d/rc 4
l5:5:wait:/etc/init.d/rc 5
l6:6:wait:/etc/init.d/rc 6
z6:6:respawn:/sbin/sulogin
ca:12345:ctrlaltdel:/sbin/shutdown -t1 -a -r now
T0:2345:respawn:/sbin/getty -L ttyS0 115200 vt100
INITTAB
fi

# --- Networking ---
cat > /etc/network/interfaces << 'EOF'
auto lo
iface lo inet loopback

auto eth0
iface eth0 inet dhcp
EOF

# --- DNS (temporary, DHCP will override) ---
echo "nameserver 1.1.1.1" > /etc/resolv.conf

# --- Set root password ---
echo "root:orangepi" | chpasswd
echo "Root password set to: orangepi (CHANGE THIS after first boot)"

# --- Allow root SSH login (for initial setup only) ---
if [ -f /etc/ssh/sshd_config ]; then
    sed -i 's/^#*PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
fi

# --- Generate SSH host keys ---
if command -v ssh-keygen >/dev/null 2>&1; then
    ssh-keygen -A
fi

# --- Set timezone ---
ln -sf /usr/share/zoneinfo/UTC /etc/localtime

# --- Update package database ---
apt-get update || echo "WARNING: apt-get update failed (expected if no network in chroot)"

# --- Clean up ---
apt-get clean
rm -f /tmp/configure-rootfs.sh

echo "=== Rootfs configuration complete ==="
echo "Default login: root / orangepi"
