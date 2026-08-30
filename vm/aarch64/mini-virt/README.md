# AArch64 mini-virt

本目录下的脚本会构建并启动以下 Git submodule 对应的组件：

- `$REPO_ROOT/qemu`：包含 `mini-virt` machine 的 `qemu-system-aarch64`
- `$REPO_ROOT/linux`：精简的 arm64 `Image` 和 `mini-virt.dtb`
- `$REPO_ROOT/busybox`：打包为 gzip initramfs 的静态链接 AArch64 userspace

每个 repository 都将 build output 保存在自身的 `build/` 目录中：

- `$REPO_ROOT/qemu/build/qemu-system-aarch64`
- `$REPO_ROOT/linux/build/arch/arm64/boot/Image` 和配套 DTB
- `$REPO_ROOT/busybox/build/`，包括 `_install`、`rootfs` 和 `initramfs.cpio.gz`

## Prerequisites

在 Ubuntu 上需要安装：

```sh
sudo apt install build-essential gcc-aarch64-linux-gnu ninja-build \
    pkg-config libglib2.0-dev libpixman-1-dev flex bison bc rsync gzip
```

## VM Boot Contract

- QEMU machine：自定义 `mini-virt`
- CPU：machine 默认的 Cortex-A57，使用 `-smp 2` 启动两个 vCPU
- 内存：固定使用 `-m 4G`，对应 machine 从 `0x40000000` 开始的 4 GiB RAM 映射
- kernel：`$REPO_ROOT/linux/build/arch/arm64/boot/Image`
- DTB：构建 `mini-virt.dtb` 并通过 `-dtb` 显式传入，描述 GICv3、architectural
  timer、PL011、sec 和 PSCI
- sec：1 KB MMIO register 空间映射到 `0x0a000000-0x0a0003ff`，使用 PL011 UART
  后一个 SPI 2（GIC INTID 34），触发类型为 level-high；register 仅支持对齐的
  U32 访问；`DATA1`、`DATA2`、`CMD`、`RESULT` 偏移分别为 `0x00`、`0x04`、
  `0x08`、`0x0c`，`IRQ_STATUS` 偏移为 `0x10`。向 `CMD` 写 1 时
  `RESULT = DATA1 xor DATA2`，置位 `IRQ_STATUS.bit0` 并上报中断；向
  `IRQ_STATUS.bit0` 写 1 清除中断，向 `CMD` 写 0 清零 `RESULT`；`RESULT` 为
  只读寄存器，其余地址保留
- sec Linux driver：`CONFIG_SYSLAB_SEC=y`，匹配 DT compatible `syslab,sec`，并通过
  miscdevice 暴露 `/dev/sec` 字符设备；`write` 传入两个 U32 操作数并执行 XOR，
  等待对应 IRQ handler 完成后返回；handler 打印 `[sec-irq]: result=...` 并清除
  level interrupt；`read` 返回
  U32 结果，`SEC_IOC_CLEAR` ioctl 清零结果，`SEC_IOC_GET_IRQ_COUNT` 返回已处理的
  中断次数
- sec 设备和 Linux driver 验证步骤见 [`sec.md`](sec.md)
- mini-virt SoC 的演进、软硬协同方法和验证边界见 [`SoC.md`](SoC.md)
- initramfs：`$REPO_ROOT/busybox/build/initramfs.cpio.gz`，根目录包含静态链接的
  sec driver userspace 测试程序 `/sec.bin`；该程序由 `tests/Makefile` 构建
- kernel boot parameter：
  `console=ttyAMA0 earlycon=pl011,0x09000000 rdinit=/init panic=-1`
- PID 1：initramfs 中的 `/init`，挂载 pseudo-filesystem 后在 `ttyAMA0` 启动
  BusyBox shell；退出 shell 后执行 `poweroff -f`

## Build and Run

```sh
cd vm/aarch64/mini-virt
./build-all.sh
./run.sh
```

guest 会在 `ttyAMA0` 上启动交互式 BusyBox shell

- 执行 `exit` 或 `poweroff` 可正常关闭 guest
- 按 `Ctrl-a c` 进入 QEMU monitor 后输入 `q` 可退出 QEMU

如需单独重建某个组件，运行对应的 `build-*.sh` 脚本
