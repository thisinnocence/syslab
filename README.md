# Syslab

Syslab 是用于学习 system programming 的 QEMU system laboratory，配套维护：

- QEMU
- Linux kernel
- BusyBox

## Project Goals

本仓库不以支持大量 VM 类型或构建通用 VM 平台为目标。每个
`vm/<arch>/<machine>/` 都是一个可独立修改的系统实验环境，用于完成以下闭环：

1. 在 QEMU 中修改 machine 或 device model
2. 配套调整设备接口及 DTS/DTB 等 hardware description
3. 在 Linux kernel 中配置、实现或修改对应 driver
4. 启动 guest，并通过最小 BusyBox userspace 验证完整行为

通过保留从硬件模型、kernel 到 userspace 的完整路径，使每项实验都能用于理解和实践
system 领域的编程。

## Evolution Principles

VM 类型保持有限，演进重点是围绕已有 VM 深入完成 system 组件之间的配套修改。
每项实验优先保证实现路径显式、容易跟踪和修改，而不是追求通用化或消除所有重复。
这样可以让一次修改从仿真模型贯通到 guest 行为，形成可复现、可扩展的学习路径。

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
