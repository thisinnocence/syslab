# RISC-V virt VM

脚本会构建并启动以下 Git submodule 对应的组件：

- `$REPO_ROOT/qemu`：包含标准 `virt` machine 的 `qemu-system-riscv64`
- `$REPO_ROOT/linux`：精简的 RISC-V `Image`
- `$REPO_ROOT/busybox`：打包为 gzip initramfs 的静态链接 RISC-V userspace

每个 repository 都将生成物保存在自身的 `build/` 目录中：

- `$REPO_ROOT/qemu/build/qemu-system-riscv64`
- `$REPO_ROOT/linux/build/arch/riscv/boot/Image`
- `$REPO_ROOT/busybox/build/`，包括 `_install`、`rootfs` 和
  `initramfs.cpio.gz`

## 前置依赖

在 Ubuntu 上需要安装：

```sh
sudo apt install build-essential gcc-riscv64-linux-gnu ninja-build \
    pkg-config libglib2.0-dev libpixman-1-dev flex bison bc rsync gzip
```

QEMU 仅构建无图形界面的 `riscv64-softmmu`

## VM 启动约定

- QEMU machine：标准 RISC-V `virt`
- CPU：machine 默认的 QEMU 通用 `rv64` CPU，使用 `-smp 2` 启动两个 vCPU
- 内存：`-m 1G`
- kernel：`$REPO_ROOT/linux/build/arch/riscv/boot/Image`
- DTB：由 QEMU 根据 `virt` machine 运行时生成，描述 SBI、PLIC、timer 和
  ns16550a UART，不单独传入 `-dtb`
- initramfs：`$REPO_ROOT/busybox/build/initramfs.cpio.gz`
- kernel boot parameter：`console=ttyS0 earlycon=sbi rdinit=/init panic=-1`
- PID 1：initramfs 中的 `/init`，挂载 pseudo-filesystem 后在 `ttyS0` 启动
  BusyBox shell；退出 shell 后执行 `poweroff -f`

## 构建和运行

```sh
cd vm/riscv64/virt
./build-all.sh
./run.sh
```

QEMU 会为标准 `virt` machine 自动生成 DTB。guest 在 `ttyS0` 上启动交互式 BusyBox shell

- 执行 `exit` 或 `poweroff` 可正常关闭 guest
- 按 `Ctrl-a c` 进入 QEMU monitor 后输入 `q` 可退出 QEMU

如需单独重建某个组件，运行对应的 `build-*.sh` 脚本
