#!/usr/bin/env bash

# 在自定义 mini-virt machine 上 direct boot 自定义内核
# machine implementation 将 4 GiB 内存映射到 0x40000000，因此 -m 必须保持为 4G
# 以确保 QEMU 生成的 DTB memory node 与实际 address space 一致

set -euo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(git -C "${SCRIPT_DIR}" rev-parse --show-toplevel)
QEMU_BIN="${REPO_ROOT}/qemu/build/qemu-system-aarch64"

# exec 以 QEMU 替换当前 shell，使终端信号直接传递给 QEMU，并保留其退出码
# - rdinit=/init 指定 initramfs 内作为 PID 1 执行的程序
# - panic=-1 使 kernel panic 后不自动重启，以便保留现场调试
exec "${QEMU_BIN}" \
    -machine mini-virt \
    -smp 2 \
    -m 4G \
    -nographic \
    -kernel "${REPO_ROOT}/linux/build/arch/arm64/boot/Image" \
    -dtb "${REPO_ROOT}/linux/build/arch/arm64/boot/dts/demo/mini-virt.dtb" \
    -initrd "${REPO_ROOT}/busybox/build/initramfs.cpio.gz" \
    -append "console=ttyAMA0 earlycon=pl011,0x09000000 rdinit=/init panic=-1"
