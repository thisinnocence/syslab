#!/usr/bin/env bash

# 作用：验证仓库脚本语法和未提交改动的格式
# 意图：在修改脚本或配置后快速发现基础错误
# 实现：遍历 VM 脚本，检查 init.sh，并执行 git diff --check

SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(git -C "${SCRIPT_DIR}" rev-parse --show-toplevel)

# 检查共享 VM helper 脚本的 Bash 语法
for script in "${REPO_ROOT}"/vm/*.sh; do
    bash -n "${script}"
done

# 检查所有 VM 构建和启动脚本的 Bash 语法
for script in "${REPO_ROOT}"/vm/*/*/*.sh; do
    bash -n "${script}"
done

# init.sh 使用 POSIX sh
for init_script in "${REPO_ROOT}"/vm/*/*/init.sh; do
    [ ! -f "${init_script}" ] || sh -n "${init_script}"
done

# 检查未提交改动中的行尾空白等格式错误
git -C "${REPO_ROOT}" diff --check
