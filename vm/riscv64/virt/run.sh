#!/usr/bin/env bash

# 在 QEMU 标准 virt machine 上 direct boot RISC-V 内核
# QEMU 会在运行时提供 virt DTB，因此不需要单独传入 -dtb
set -euo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(git -C "${SCRIPT_DIR}" rev-parse --show-toplevel)

# exec 以 QEMU 替换当前 shell，使终端信号直接传递给 QEMU，并保留其退出码
# - rdinit=/init 指定 initramfs 内作为 PID 1 执行的程序
# - panic=-1 使 kernel panic 后不自动重启，以便保留现场调试
exec "${REPO_ROOT}/qemu/build/qemu-system-riscv64" \
    -machine virt \
    -smp 2 \
    -m 1G \
    -nographic \
    -kernel "${REPO_ROOT}/linux/build/arch/riscv/boot/Image" \
    -initrd "${REPO_ROOT}/busybox/build/initramfs.cpio.gz" \
    -append "console=ttyS0 earlycon=sbi rdinit=/init panic=-1"
