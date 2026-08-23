# Syslab

用于构建和运行最小化 QEMU virtual machine 的 System and Architecture lab。

首次获取 repository 后初始化 submodule：

```sh
git submodule update --init --recursive
```

## Supported VMs

| Arch | QEMU VM | 说明 | 入口 |
| --- | --- | --- | --- |
| AArch64 | `mini-virt` | 自定义的最小 ARM vm，使用配套 DTS | [README](vm/aarch64/mini-virt/README.md) |
| AArch64 | `virt` | QEMU 标准 ARM `virt` vm，使用 Cortex-A72 和 QEMU 生成的 DTB | [README](vm/aarch64/virt/README.md) |
| RISC-V 64 | `virt` | QEMU 标准 RISC-V `virt` vm，由 QEMU 生成 DTB | [README](vm/riscv64/virt/README.md) |

## Build and Run

以 RISC-V `virt` 为例：

```sh
cd vm/riscv64/virt
./build-all.sh
./run.sh
```

guest 启动后进入 BusyBox shell：

- 执行 `exit` 或 `poweroff` 可正常关闭 guest
- 按 `Ctrl-a c` 进入 QEMU monitor 后输入 `q` 可退出 QEMU
