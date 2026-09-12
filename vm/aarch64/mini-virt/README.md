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
  timer、PL011、SMMUv3、sec 和 PSCI
- SMMUv3：128 KiB MMIO `0x0b000000-0x0b01ffff`，SPI 3–6，Stage 1 coherent DMA；
  SEC 四个 VF 分别使用 SID 1–4，不涉及 PCIe、ITS/MSI、ATS/PRI、SVA 或 Stage 2
- SEC：一个片内设备，四个固定 VF，各有 4 KB MMIO 窗口
  `0x0a000000 + VF_ID * 0x1000`、SPI `8 + VF_ID`（GIC INTID 40–43，level-high）
  和独立 DMA AddressSpace；每个 VF 支持 PIO XOR、DMA copy、完成 IRQ 和本地复位
- SEC Linux driver：`CONFIG_SYSLAB_SEC=y`，匹配四个 `syslab,sec-vf` DT 节点，各有
  独立 DMA domain、buffer、mutex 和 completion，暴露 `/dev/sec0`–`/dev/sec3`；每个 VF
  独占 open，最后 close 或进程退出后清理；同一 VF 同步执行请求，不同 VF 可并发使用
- SEC UAPI：保留 XOR/clear/IRQ count 和 1–64 bytes DMA copy，新增 VF 信息查询、本地
  复位及默认关闭的受控 IOVA fault 测试；应用选择对应 `/dev/secN`，不直接传入 DMA address
- sec 设备和 Linux driver 验证步骤见 [`sec.md`](sec.md)
- SMMUv3 topology、SID、IOVA translation 和验证步骤见 [`smmu.md`](smmu.md)
- mini-virt SoC 的演进、软硬协同方法和验证边界见 [`SoC.md`](SoC.md)
- initramfs：`$REPO_ROOT/busybox/build/initramfs.cpio.gz`，根目录包含静态链接的
  sec driver userspace 测试程序 `/sec.bin`；该程序由 `tests/Makefile` 构建
- kernel boot parameter：
  `console=ttyAMA0 earlycon=pl011,0x09000000 rdinit=/init panic=-1 sec.fault_test=0`
  （`SEC_FAULT_TEST=1` 启动时将最后一项设为 1）
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

## SEC 多进程验证

在 guest 中运行 `./sec.bin --all`，检查四个 VF 的 XOR/DMA/IRQ、独占访问、复位隔离、
四进程各 200 轮并发和 SIGKILL 后重新打开，预期 `sec test: PASS` 且退出码为 0。
默认 `./sec.bin` 只测 VF0，`./sec.bin --vf 2` 选择 VF2。

host 使用 `SEC_FAULT_TEST=1 ./vm/aarch64/mini-virt/run.sh` 重新启动后，guest 执行
`./sec.bin --all --fault`，进一步验证映射撤销后的旧 IOVA 被拒绝及 DMA 恢复。
这是同一 guest 内的功能隔离实验；尚不包含跨 VM 直通、异步 DMA 或性能仿真。

## PSCI 与 CPU hotplug

本 profile 使用 TCG 内置 PSCI 1.1 仿真，conduit 为 SMC，无需 TF-A。
CPU0 由 QEMU direct boot；CPU1 初始 powered-off，由 Linux `CPU_ON` 启动。
DTS 的 CPU 节点使用 `enable-method = "psci"`；QEMU 在加载 DTB 时根据实际
conduit 重建 `/psci`。内核启用 `CONFIG_ARM_PSCI_FW=y` 和 `CONFIG_HOTPLUG_CPU=y`。

host 使用 `PSCI_TRACE=/tmp/mini-virt-psci.trace ./run.sh` 记录 PSCI 请求和
`arm_powerctl_*` API；不设置该变量时不额外开启 trace。
initramfs 包含 `/psci.sh`，在 guest 中执行会对 CPU1 做三轮 offline/online，
检查 online/present 状态，最终恢复双核在线并输出 `psci test: PASS`。
也可直接使用 `echo 0` / `echo 1` 写 `/sys/devices/system/cpu/cpu1/online`。
测试保留 CPU0 在线；CPU offline 不删除 vCPU 对象，也不模拟物理电源时序。

验收时结合启动日志中的 CPU0/CPU1、`CPU1 killed`、guest 测试结果和 host trace，
确认 CPU_ON、CPU_OFF、AFFINITY_INFO 均被调用。随后运行 `/sec.bin --all` 验证
现有 SEC/SMMU 链路，执行 `poweroff -f` 验证 SYSTEM_OFF 和 QEMU 正常退出。
原理、核心 API、关键调用链和完整操作见 [`docs/psci.md`](../../../docs/psci.md)。

QEMU 构建固定使用 `--enable-debug`（`-O0 -g`），便于获取 host GDB 调用栈。
已有 build 若配置不同，按 configure-time 变更约定只清空 `qemu/build` 后重建。
PSCI trace 还包含 reset、firmware reset、PSCI 返回值、CPU_OFF 入队及上下电完成状态。
原始 GDB `bt`、状态快照和完整 trace 已收录于 `docs/psci.md`；可从 repository
root 使用 `tests/psci.gdb` 配合该文档的 GDB 命令重新采集。
