#!/usr/bin/env bash

# 在 QEMU 标准 virt machine 上 direct boot arm64 内核
# QEMU 会在运行时提供 virt DTB，因此不需要单独传入 -dtb
set -euo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(git -C "${SCRIPT_DIR}" rev-parse --show-toplevel)

for build_dir in qemu linux busybox; do
    "${REPO_ROOT}/vm/build-profile.sh" require aarch64/virt \
        "${REPO_ROOT}/${build_dir}/build"
done

# exec 以 QEMU 替换当前 shell，使终端信号直接传递给 QEMU，并保留其退出码
# -cpu cortex-a72 指定常见的 ARMv8-A application CPU
# - rdinit=/init 指定 initramfs 内作为 PID 1 执行的程序
# - panic=-1 使 kernel panic 后不自动重启，以便保留现场调试
exec "${REPO_ROOT}/qemu/build/qemu-system-aarch64" \
    -machine virt \
    -cpu cortex-a72 \
    -smp 2 \
    -m 1G \
    -nographic \
    -kernel "${REPO_ROOT}/linux/build/arch/arm64/boot/Image" \
    -initrd "${REPO_ROOT}/busybox/build/initramfs.cpio.gz" \
    -append "console=ttyAMA0 earlycon=pl011,0x09000000 rdinit=/init panic=-1"
