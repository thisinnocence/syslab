#!/usr/bin/env bash

# 在 qemu/build 下构建 QEMU 的 AArch64 system emulator
set -euo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(git -C "${SCRIPT_DIR}" rev-parse --show-toplevel)
QEMU_SRC="${REPO_ROOT}/qemu"
QEMU_BUILD="${QEMU_SRC}/build"
QEMU_BIN="${QEMU_BUILD}/qemu-system-aarch64"
JOBS=${JOBS:-$(nproc)}

"${REPO_ROOT}/vm/build-profile.sh" claim aarch64/mini-virt "${QEMU_BUILD}"

# 首次构建时执行 configure
# 如需修改 configure-time 选项，删除 qemu/build 后重新构建
if [[ ! -f "${QEMU_BUILD}/build.ninja" ]]; then
    (
        cd "${QEMU_BUILD}"
        "${QEMU_SRC}/configure" \
            --target-list=aarch64-softmmu \
            --disable-docs \
            --disable-gtk \
            --disable-sdl
    )
fi

# Ninja 根据依赖关系只重新编译变更的源码
# 源码未变更时，构建会直接完成而不会重新编译
ninja -C "${QEMU_BUILD}" -j "${JOBS}" qemu-system-aarch64
echo "QEMU ready: ${QEMU_BIN}"
