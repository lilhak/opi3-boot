# Orange Pi 3 LTS - 32-bit SMP Linux Boot Project

## Target
- Board: Orange Pi 3 LTS (Allwinner H6, ARM Cortex-A53, 64-bit capable)
- Boot medium: external 32GB SD card
- Userspace: Devuan Daedalus (repository-based root filesystem)
- Kernel goal: 32-bit Linux SMP kernel
- End state: boots fully to shell with normal userspace processes

## Core Requirement
Devuan Daedalus userspace (packages, init system, repos), but kernel and boot chain do NOT need to come from Devuan if another source is more practical.

## Decision Authority
Choose: bootloader approach, kernel source/version, rootfs creation method, cross-toolchain, SD-card partition layout. Prefer proven upstream-supported components.

## Required Output Structure
1. Goal Summary
2. Feasibility
3. Recommended Boot Path
4. Assumptions
5. Step-by-Step Build Instructions
6. Bootloader Config
7. Kernel Config
8. Devuan Daedalus Rootfs Setup
9. SD Card Image / Flash Layout
10. Validation Checklist
11. Debugging Matrix
12. Risks / Constraints
13. First Coding Tasks

## Edge Cases to Handle
- 64-bit-capable SoC with 32-bit kernel target
- Devuan userspace with a non-native kernel
- kernel boots but SMP fails
- userspace mounts but init/services fail
- SD-card offsets, partitioning, or boot sectors incorrect
- device tree mismatches
