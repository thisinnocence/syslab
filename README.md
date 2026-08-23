# Syslab

用于构建和运行 QEMU VM 的 System laboratory , 包括：

- QEMU
- Linux kernel
- BusyBox

的配套构建和运行。

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
