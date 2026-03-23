FROM debian:bookworm

RUN apt-get update && apt-get install -y \
    build-essential \
    gcc-arm-linux-gnueabihf \
    g++-arm-linux-gnueabihf \
    bc \
    bison \
    flex \
    libssl-dev \
    libncurses-dev \
    u-boot-tools \
    device-tree-compiler \
    swig \
    python3-dev \
    python3-setuptools \
    git \
    wget \
    curl \
    parted \
    dosfstools \
    e2fsprogs \
    kpartx \
    debootstrap \
    qemu-user-static \
    debian-keyring \
    gnupg \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build
