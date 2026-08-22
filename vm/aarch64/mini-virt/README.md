# AArch64 mini-virt VM

脚本会构建并启动以下 Git submodule 对应的组件：

- `$REPO_ROOT/qemu`：包含 `mini-virt` machine 的 `qemu-system-aarch64`
- `$REPO_ROOT/linux`：精简的 arm64 `Image` 和 `mini-virt.dtb`
- `$REPO_ROOT/busybox`：打包为 gzip initramfs 的静态链接 AArch64 userspace

每个 repository 都将生成物保存在自身的 `build/` 目录中：

- `$REPO_ROOT/qemu/build/qemu-system-aarch64`
- `$REPO_ROOT/linux/build/arch/arm64/boot/Image` 和配套 DTB
- `$REPO_ROOT/busybox/build/`，包括 `_install`、`rootfs` 和 `initramfs.cpio.gz`

## 前置依赖

在 Ubuntu 上需要安装：

```sh
sudo apt install build-essential gcc-aarch64-linux-gnu ninja-build \
    pkg-config libglib2.0-dev libpixman-1-dev flex bison bc rsync gzip
```

QEMU 仅构建无图形界面的 `aarch64-softmmu`

## 构建和运行

```sh
cd vm/aarch64/mini-virt
build-all.sh
run.sh
```

guest 会在 `ttyAMA0` 上启动交互式 BusyBox shell。按 `Ctrl-a x` 退出 QEMU
如需单独重建某个组件，运行对应的 `build-*.sh` 脚本。
