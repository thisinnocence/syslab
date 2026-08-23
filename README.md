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

- VM profile 保持少量、明确且可独立运行
- arch、machine 和实验专属的脚本、配置及说明保留在对应 VM 目录中
- 优先保证实现路径显式、容易跟踪和修改，不以消除少量重复为目标
- 共享基础设施只处理 build ownership、仓库级验证等跨 profile 一致性问题，不隐藏
  machine、device 或 kernel 的关键行为
- 每个 VM 的 README 记录其 boot、device、kernel、initramfs 和 userspace contract

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
