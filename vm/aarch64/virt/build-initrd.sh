#!/usr/bin/env bash

# 不依赖宿主机的 cpio 命令，生成 busybox/build/initramfs.cpio.gz
set -euo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(git -C "${SCRIPT_DIR}" rev-parse --show-toplevel)
LINUX_SRC="${REPO_ROOT}/linux"
LINUX_BUILD="${LINUX_SRC}/build"
BUSYBOX_BUILD="${REPO_ROOT}/busybox/build"
BUSYBOX_INSTALL="${BUSYBOX_BUILD}/_install"
ROOTFS_DIR="${BUSYBOX_BUILD}/rootfs"
INITRD_IMAGE="${BUSYBOX_BUILD}/initramfs.cpio.gz"

"${REPO_ROOT}/vm/build-profile.sh" require aarch64/virt "${LINUX_BUILD}"
"${REPO_ROOT}/vm/build-profile.sh" require aarch64/virt "${BUSYBOX_BUILD}"

# ROOTFS_DIR 是由这些脚本管理的生成目录
rm -rf -- "${ROOTFS_DIR}"
mkdir -p "${ROOTFS_DIR}"/{dev,etc,proc,sys,tmp,root}
chmod 1777 "${ROOTFS_DIR}/tmp"
rsync -a "${BUSYBOX_INSTALL}/" "${ROOTFS_DIR}/"

cat >"${ROOTFS_DIR}/etc/fstab" <<'EOF'
devtmpfs /dev  devtmpfs defaults 0 0
proc     /proc proc     defaults 0 0
sysfs    /sys  sysfs    defaults 0 0
EOF

# /init 以普通 Shell 脚本维护，便于编辑器高亮和独立检查；打包时复制到
# 生成的 initramfs 根目录
install -m 0755 "${SCRIPT_DIR}/init.sh" "${ROOTFS_DIR}/init"

# 在内核 build 目录中运行辅助脚本，因为 gen_initramfs.sh 会相对于当前目录
# 查找 usr/gen_init_cpio
# 该脚本生成保留 rootfs 布局和文件权限的 cpio archive；gzip 用于减小镜像，
# 内核启动时会自动解压
(
    cd "${LINUX_BUILD}"
    "${LINUX_SRC}/usr/gen_initramfs.sh" -u squash -g squash \
        "${ROOTFS_DIR}"
) | gzip -9 >"${INITRD_IMAGE}"
echo "Initramfs ready: ${INITRD_IMAGE}"
