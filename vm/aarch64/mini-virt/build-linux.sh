#!/usr/bin/env bash

# 在 linux/build 下构建精简的 arm64 Image 及配套 DTB
set -euo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(git -C "${SCRIPT_DIR}" rev-parse --show-toplevel)
LINUX_SRC="${REPO_ROOT}/linux"
LINUX_BUILD="${LINUX_SRC}/build"
KERNEL_IMAGE="${LINUX_BUILD}/arch/arm64/boot/Image"
KERNEL_DTB="${LINUX_BUILD}/arch/arm64/boot/dts/demo/mini-virt.dtb"
ARCH=arm64
CROSS_COMPILE=${CROSS_COMPILE:-aarch64-linux-gnu-}
JOBS=${JOBS:-$(nproc)}

"${REPO_ROOT}/vm/build-profile.sh" claim aarch64/mini-virt "${LINUX_BUILD}"

# KCONFIG_ALLCONFIG 将指定的 symbol 作为 allnoconfig 的输入
# olddefconfig 随后解析依赖关系，并确定性地补全新引入的 symbol
make -C "${LINUX_SRC}" O="${LINUX_BUILD}" ARCH="${ARCH}" \
    CROSS_COMPILE="${CROSS_COMPILE}" \
    KCONFIG_ALLCONFIG="${SCRIPT_DIR}/linux.config" allnoconfig
make -C "${LINUX_SRC}" O="${LINUX_BUILD}" ARCH="${ARCH}" \
    CROSS_COMPILE="${CROSS_COMPILE}" olddefconfig

# Image 是 QEMU direct boot 所需的未压缩 arm64 内核镜像
make -C "${LINUX_SRC}" O="${LINUX_BUILD}" ARCH="${ARCH}" \
    CROSS_COMPILE="${CROSS_COMPILE}" -j "${JOBS}" \
    Image demo/mini-virt.dtb

echo "Kernel ready: ${KERNEL_IMAGE}"
echo "DTB ready:    ${KERNEL_DTB}"
