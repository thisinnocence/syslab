#!/usr/bin/env bash

# =============================================================================
# 作用：删除所有共享 component 的 build output
# 意图：切换 VM build profile 前清理旧 profile 的构建结果和 ownership marker
# 实现：在每个 submodule 中仅清理其 build 目录
# =============================================================================

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(git -C "${SCRIPT_DIR}" rev-parse --show-toplevel)

for component in qemu linux busybox; do
    echo "Removing ${component}/build"
    git -C "${REPO_ROOT}/${component}" clean -fdx -- build
done
