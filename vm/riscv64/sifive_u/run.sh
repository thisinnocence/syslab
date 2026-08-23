#!/usr/bin/env bash

# 在 QEMU SiFive HiFive Unleashed machine 上 direct boot RISC-V 内核
# QEMU 会在运行时提供 sifive_u DTB，因此不需要单独传入 -dtb
set -euo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(git -C "${SCRIPT_DIR}" rev-parse --show-toplevel)

for build_dir in qemu linux busybox; do
    "${REPO_ROOT}/vm/build-profile.sh" require riscv64/sifive_u \
        "${REPO_ROOT}/${build_dir}/build"
done

# exec 以 QEMU 替换当前 shell，使终端信号直接传递给 QEMU，并保留其退出码
# - rdinit=/init 指定 initramfs 内作为 PID 1 执行的程序
# - panic=-1 使 kernel panic 后不自动重启，以便保留现场调试
exec "${REPO_ROOT}/qemu/build/qemu-system-riscv64" \
    -machine sifive_u \
    -smp 5 \
    -m 2G \
    -nographic \
    -no-reboot \
    -bios default \
    -kernel "${REPO_ROOT}/linux/build/arch/riscv/boot/Image" \
    -initrd "${REPO_ROOT}/busybox/build/initramfs.cpio.gz" \
    -append "console=ttySIF0 earlycon=sbi rdinit=/init panic=-1"
