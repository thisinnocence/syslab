# Syslab

用于构建和运行最小化 QEMU virtual machine 的 System and Architecture lab。
每个 VM 都由本仓库中的 QEMU、Linux 和 BusyBox Git submodule 配套构建，并通过
`initramfs` 启动到串口上的交互 shell。

## Repository 结构

- `qemu/`：QEMU Git submodule，可构建所需的 system emulator
- `linux/`：Linux Git submodule，可构建对应 arch 的 kernel image
- `busybox/`：BusyBox Git submodule，用于生成静态链接的 initramfs userspace
- `vm/<arch>/<machine>/`：特定 arch 与 machine 的构建、启动脚本和说明文档

首次获取 repository 后初始化 submodule：

```sh
git submodule update --init --recursive
```

## 已支持的 VM

| Arch | QEMU machine | 说明 | 入口 |
| --- | --- | --- | --- |
| AArch64 | `mini-virt` | 自定义的最小 ARM machine，使用配套 DTS | [README](vm/aarch64/mini-virt/README.md) |
| RISC-V 64 | `virt` | QEMU 标准 RISC-V VirtIO board，由 QEMU 生成 DTB | [README](vm/riscv64/virt/README.md) |

每个 VM 目录都提供：

- `build-qemu.sh`、`build-linux.sh`、`build-busybox.sh`、`build-initrd.sh`：分别构建组件
- `build-all.sh`：按依赖顺序构建全部组件
- `run.sh`：direct boot kernel 与 initramfs，并连接到串口
- `linux.config`、`busybox.config`、`init.sh`：最小 kernel、userspace 和 PID 1 配置

## 构建和运行

每次只构建一个 VM。切换 VM 或修改 QEMU 的 configure-time 选项前，清空
`qemu/build`、`linux/build` 和 `busybox/build`。完整的构建与验证约定见
[AGENT.md](AGENT.md)

以 RISC-V `virt` 为例：

```sh
cd vm/riscv64/virt
./build-all.sh
./run.sh
```

guest 启动后进入 BusyBox shell：

- 若 machine 与 kernel 支持关机，执行 `poweroff` 可正常关闭 guest
- 按 `Ctrl-a c` 进入 QEMU monitor 后输入 `q` 可退出 QEMU

每个 VM 的依赖、kernel boot parameter、设备和路径说明以该目录的 `README.md` 为准。
