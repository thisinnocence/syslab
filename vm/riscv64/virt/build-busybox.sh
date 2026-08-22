#!/usr/bin/env bash

# 在 busybox/build 下交叉编译静态链接的 BusyBox
set -euo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(git -C "${SCRIPT_DIR}" rev-parse --show-toplevel)
BUSYBOX_SRC="${REPO_ROOT}/busybox"
BUSYBOX_BUILD="${BUSYBOX_SRC}/build"
BUSYBOX_INSTALL="${BUSYBOX_BUILD}/_install"
ARCH=riscv
CROSS_COMPILE=${CROSS_COMPILE:-riscv64-linux-gnu-}
JOBS=${JOBS:-$(nproc)}

"${REPO_ROOT}/vm/build-profile.sh" claim riscv64/virt "${BUSYBOX_BUILD}"

# 从不启用任何 applet 的配置开始，再应用最小 BusyBox 配置
make -C "${BUSYBOX_SRC}" O="${BUSYBOX_BUILD}" ARCH="${ARCH}" \
    CROSS_COMPILE="${CROSS_COMPILE}" allnoconfig

while IFS= read -r assignment; do
    [[ "${assignment}" == CONFIG_*=* ]] || continue
    symbol=${assignment%%=*}
    sed -i \
        -e "/^${symbol}=/d" \
        -e "/^# ${symbol} is not set$/d" \
        "${BUSYBOX_BUILD}/.config"
    printf '%s\n' "${assignment}" >>"${BUSYBOX_BUILD}/.config"
done <"${SCRIPT_DIR}/busybox.config"

# silentoldconfig 解析依赖并为新增 symbol 使用默认值，不进入交互式问答
make -C "${BUSYBOX_SRC}" O="${BUSYBOX_BUILD}" ARCH="${ARCH}" \
    CROSS_COMPILE="${CROSS_COMPILE}" silentoldconfig

make -C "${BUSYBOX_SRC}" O="${BUSYBOX_BUILD}" ARCH="${ARCH}" \
    CROSS_COMPILE="${CROSS_COMPILE}" -j "${JOBS}"
make -C "${BUSYBOX_SRC}" O="${BUSYBOX_BUILD}" ARCH="${ARCH}" \
    CROSS_COMPILE="${CROSS_COMPILE}" CONFIG_PREFIX="${BUSYBOX_INSTALL}" install

echo "BusyBox root ready: ${BUSYBOX_INSTALL}"
