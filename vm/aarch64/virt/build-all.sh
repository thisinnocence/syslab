#!/usr/bin/env bash

# 按依赖顺序构建各组件
# initrd 依赖 BusyBox 的安装结果和 Linux 提供的 host cpio generator，因此最后构建
set -euo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" && pwd)

"${SCRIPT_DIR}/build-qemu.sh"
"${SCRIPT_DIR}/build-linux.sh"
"${SCRIPT_DIR}/build-busybox.sh"
"${SCRIPT_DIR}/build-initrd.sh"

echo "All AArch64 virt artifacts are ready. Run ${SCRIPT_DIR}/run.sh"
