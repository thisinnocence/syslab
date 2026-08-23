# RISC-V SiFive HiFive Unleashed

SiFive HiFive Unleashed 是一块基于 Freedom U540 多核 RISC-V processor 的开发板。
QEMU 的 `sifive_u` machine 模拟其 board-level hardware layout：真实板卡固定包含 1 个
E51 management hart 和 4 个 U54 application hart，以及 CLINT、PLIC、PRCI、UART 等设备。

它不同于仅面向虚拟机的通用 `virt` platform，适合学习一块具体 RISC-V board 的 firmware、
hardware description 与 Linux 之间的配合。

本目录下的脚本会构建并启动以下 Git submodule 对应的组件：

- `$REPO_ROOT/qemu`：包含 `sifive_u` machine 的 `qemu-system-riscv64`
- `$REPO_ROOT/linux`：精简的 RISC-V `Image`
- `$REPO_ROOT/busybox`：打包为 gzip initramfs 的静态链接 RISC-V userspace

每个 repository 都将 build output 保存在自身的 `build/` 目录中：

- `$REPO_ROOT/qemu/build/qemu-system-riscv64`
- `$REPO_ROOT/linux/build/arch/riscv/boot/Image`
- `$REPO_ROOT/busybox/build/`，包括 `_install`、`rootfs` 和
  `initramfs.cpio.gz`

## Prerequisites

在 Ubuntu 上需要安装：

```sh
sudo apt install build-essential gcc-riscv64-linux-gnu ninja-build \
    pkg-config libglib2.0-dev libpixman-1-dev flex bison bc rsync gzip
```

## VM Boot Contract

- QEMU machine：`sifive_u`，模拟 SiFive HiFive Unleashed / Freedom U540 SoC
- CPU：1 个 E51 management hart 和 4 个 U54 application hart；使用 `-smp 5`，
  Linux 使用 4 个 U54 hart
- 内存：`-m 2G`
- firmware：QEMU 自带的 OpenSBI，由 `-bios default` 加载
- kernel：`$REPO_ROOT/linux/build/arch/riscv/boot/Image`
- DTB：由 QEMU 根据 `sifive_u` machine 运行时生成，描述 FU540 hart、CLINT、
  PLIC、PRCI 和 SiFive UART，不单独传入 `-dtb`
- initramfs：`$REPO_ROOT/busybox/build/initramfs.cpio.gz`
- kernel boot parameter：`console=ttySIF0 earlycon=sbi rdinit=/init panic=-1`
- shutdown：`sifive_u` 没有 emulated shutdown device；QEMU 使用 `-no-reboot`，
  PID 1 在 `exit`、`poweroff` 或 `halt` 后请求 reset，使 emulator process 退出

本 profile 使用 QEMU direct boot，重点验证真实 board model、OpenSBI、Linux 和
initramfs 的最小链路；不包含真实 HiFive Unleashed 的 QSPI/SD card U-Boot bootflow.

## Build and Run

```sh
cd vm/riscv64/sifive_u
./build-all.sh
./run.sh
```

QEMU 会为 `sifive_u` machine 自动生成 DTB. guest 在 `ttySIF0` 上启动交互式
BusyBox shell.

- 执行 `exit`、`poweroff` 或 `halt` 可正常退出 QEMU
- 按 `Ctrl-a c` 进入 QEMU monitor 后输入 `q` 可退出 QEMU

如需单独重建某个组件，运行对应的 `build-*.sh` 脚本
