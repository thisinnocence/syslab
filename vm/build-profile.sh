#!/usr/bin/env bash

# =============================================================================
# 作用：管理 build 目录的 VM build profile ownership
#
# 意图：防止不同 VM profile 复用彼此或旧的无归属 build output
#
# 参数：
# - $1：操作模式，claim 声明目录归属，require 验证已有归属
# - $2：VM build profile 名称
# - $3：需要声明或验证 ownership 的 build 目录
#
# 实现：
# - claim：为空目录写入 .syslab-profile marker，并声明 ownership
# - require：检查 marker 是否存在且属于指定 profile
# - marker 缺失、目录非空或 ownership 不匹配时拒绝继续
# =============================================================================

set -euo pipefail

MODE=$1
PROFILE=$2
BUILD_DIR=$3
MARKER="${BUILD_DIR}/.syslab-profile"

if [[ "${MODE}" == claim ]]; then
    mkdir -p "${BUILD_DIR}"
fi

if [[ ! -f "${MARKER}" ]]; then
    if [[ "${MODE}" == claim ]] &&
        [[ -z "$(find "${BUILD_DIR}" -mindepth 1 -maxdepth 1 -print -quit)" ]]; then
        printf '%s\n' "${PROFILE}" >"${MARKER}"
        exit 0
    fi

    echo "ERROR: remove unowned build directory: ${BUILD_DIR}" >&2
    exit 1
fi

if [[ "$(<"${MARKER}")" != "${PROFILE}" ]]; then
    echo "ERROR: remove build directory owned by another VM: ${BUILD_DIR}" >&2
    echo "HINT: remove this build directory, then rebuild the VM profile" >&2
    exit 1
fi
