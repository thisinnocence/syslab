# AArch64 virt VM

脚本会构建并启动以下 Git submodule 对应的组件：

- `$REPO_ROOT/qemu`：包含标准 `virt` machine 的 `qemu-system-aarch64`
- `$REPO_ROOT/linux`：精简的 arm64 `Image`
- `$REPO_ROOT/busybox`：打包为 gzip initramfs 的静态链接 AArch64 userspace

每个 repository 都将生成物保存在自身的 `build/` 目录中：

- `$REPO_ROOT/qemu/build/qemu-system-aarch64`
- `$REPO_ROOT/linux/build/arch/arm64/boot/Image`
- `$REPO_ROOT/busybox/build/`，包括 `_install`、`rootfs` 和 `initramfs.cpio.gz`

## 前置依赖

在 Ubuntu 上需要安装：

```sh
sudo apt install build-essential gcc-aarch64-linux-gnu ninja-build \
    pkg-config libglib2.0-dev libpixman-1-dev flex bison bc rsync gzip
```

QEMU 仅构建无图形界面的 `aarch64-softmmu`

## VM 启动约定

- QEMU machine：标准 `virt`，显式使用 `gic-version=3`
- CPU：Cortex-A72，使用 `-smp 2` 启动两个 vCPU
- 内存：`-m 1G`
- kernel：`$REPO_ROOT/linux/build/arch/arm64/boot/Image`
- DTB：由 QEMU 根据 `virt,gic-version=3` 运行时生成，描述 GICv3、architectural
  timer、PL011 和 PSCI，不单独传入 `-dtb`
- initramfs：`$REPO_ROOT/busybox/build/initramfs.cpio.gz`
- kernel boot parameter：
  `console=ttyAMA0 earlycon=pl011,0x09000000 rdinit=/init panic=-1`
- PID 1：initramfs 中的 `/init`，挂载 pseudo-filesystem 后在 `ttyAMA0` 启动
  BusyBox shell；退出 shell 后执行 `poweroff -f`

## 构建和运行

```sh
cd vm/aarch64/virt
./build-all.sh
./run.sh
```

QEMU 会为标准 `virt` machine 自动生成 DTB. guest 以主流的 Cortex-A72 CPU
在 `ttyAMA0` 上启动交互式 BusyBox shell.

- 执行 `exit` 或 `poweroff` 可正常关闭 guest
- 按 `Ctrl-a c` 进入 QEMU monitor 后输入 `q` 可退出 QEMU

如需单独重建某个组件，运行对应的 `build-*.sh` 脚本
