# Syslab

Syslab 是用于学习 system programming 的 QEMU system laboratory，配套维护：

- QEMU
- Linux kernel
- BusyBox

首次 clone repository 后需要初始化 submodule：

```sh
git submodule update --init --recursive
```

## Build Profiles

每个 `vm/<arch>/<machine>/` 都是独立维护的实验 profile，但 QEMU、Linux 和
BusyBox 的 build output 分别统一放在各自 submodule 的 `build/` 目录。因此同一时间
只能有一个 active build profile。

profile 的构建脚本会通过 `build/.syslab-profile` 记录并检查 build output 的 owner，
拒绝复用其他 profile 或无 owner 的旧产物。首次构建某个 profile 时，直接进入其目录运行
`./build-all.sh`；切换到另一个 profile 前，可以先在 repository root 运行：

```sh
./vm/clean.sh
```

该命令会删除三个 submodule 的 `build/` 目录（包括其中的 owner marker）。随后进入目标 profile
重新执行 `./build-all.sh`，再运行 `./run.sh`。这样每次实验使用的 QEMU、kernel 和
BusyBox 都属于同一个 profile，不会静默混用旧的构建结果。

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

## Supported VMs

| Arch | QEMU VM | 说明 | 入口 |
| --- | --- | --- | --- |
| AArch64 | `mini-virt` | 自定义的最小 ARM vm，使用配套 DTS | [README](vm/aarch64/mini-virt/README.md) |
| AArch64 | `virt` | QEMU 标准 ARM `virt` vm，使用 Cortex-A72 和 QEMU 生成的 DTB | [README](vm/aarch64/virt/README.md) |
| RISC-V 64 | `virt` | QEMU 标准 RISC-V `virt` vm，由 QEMU 生成 DTB | [README](vm/riscv64/virt/README.md) |
| RISC-V 64 | `sifive_u` | SiFive HiFive Unleashed / Freedom U540，使用 QEMU 生成的 DTB | [README](vm/riscv64/sifive_u/README.md) |
