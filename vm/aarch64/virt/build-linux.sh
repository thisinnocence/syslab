#!/usr/bin/env bash

# 在 linux/build 下构建精简的 arm64 Image
set -euo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(git -C "${SCRIPT_DIR}" rev-parse --show-toplevel)
LINUX_SRC="${REPO_ROOT}/linux"
LINUX_BUILD="${LINUX_SRC}/build"
KERNEL_IMAGE="${LINUX_BUILD}/arch/arm64/boot/Image"
LINUX_COMPILE_COMMANDS="${LINUX_BUILD}/compile_commands.json"
ARCH=arm64
CROSS_COMPILE=${CROSS_COMPILE:-aarch64-linux-gnu-}
JOBS=${JOBS:-$(nproc)}

"${REPO_ROOT}/vm/build-profile.sh" claim aarch64/virt "${LINUX_BUILD}"

# KCONFIG_ALLCONFIG 将指定的 symbol 作为 allnoconfig 的输入
# olddefconfig 随后解析依赖关系，并确定性地补全新引入的 symbol
make -C "${LINUX_SRC}" O="${LINUX_BUILD}" ARCH="${ARCH}" \
    CROSS_COMPILE="${CROSS_COMPILE}" \
    KCONFIG_ALLCONFIG="${SCRIPT_DIR}/linux.config" allnoconfig
make -C "${LINUX_SRC}" O="${LINUX_BUILD}" ARCH="${ARCH}" \
    CROSS_COMPILE="${CROSS_COMPILE}" olddefconfig

# Image 是 QEMU direct boot 所需的未压缩 arm64 内核镜像
make -C "${LINUX_SRC}" O="${LINUX_BUILD}" ARCH="${ARCH}" \
    CROSS_COMPILE="${CROSS_COMPILE}" -j "${JOBS}" Image

# Kbuild 从已生成的 .cmd 文件提取实际编译参数，供 clangd 等使用，方便看代码
make -C "${LINUX_SRC}" O="${LINUX_BUILD}" ARCH="${ARCH}" \
    CROSS_COMPILE="${CROSS_COMPILE}" compile_commands.json

echo "Kernel ready: ${KERNEL_IMAGE}"
echo "Compile commands: ${LINUX_COMPILE_COMMANDS}"
