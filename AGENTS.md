# Syslab Agent Guide

## Repository Layout

- `qemu/`、`linux/`、`busybox/` 是 Git submodule
- `vm/<arch>/<machine>/` 保存某个 arch 和 VM 的构建、启动脚本及说明文档
- `vm/verify.sh` 保存 VM 相关的仓库级公共验证脚本

## Build Conventions

- 每个 submodule 的 build output 只能放在其自身的 `build/` 目录
- 一个 `vm/<arch>/<machine>` 目录对应一个 VM build profile
- 同一时间只保留一个 active build profile
- active build profile 独占 `qemu/build`、`linux/build` 和 `busybox/build`
- 每个 build 目录通过 `.syslab-profile` 记录其 owner
- 切换 VM build profile 时，清空这三个 build 目录后重新构建
- 构建脚本拒绝复用 owner 不匹配或没有 owner 的旧 build output
- component 的 configure-time 选项变更时，只清空对应 component 的 build 目录
- 同一 VM build profile 内使用 Make 和 Ninja 增量构建
- 在目标 VM 目录中使用 `build-all.sh` 构建全部组件，并使用 `run.sh` 启动 QEMU

## Change Scope

- 将一个 VM profile 视为一次实验的修改边界；涉及 QEMU、Linux 或 BusyBox 时同步检查整条链路
- arch、machine 和实验专属实现放在对应 VM 目录，不移动到共享层以消除少量重复
- 共享 helper 只能封装与具体 machine 无关的基础设施，并通过参数保持行为显式
- 修改一个 VM 的启动、设备或 userspace 行为时，同步更新该 VM 的 README contract
- 新增或修改跨 submodule 的实验时，分别验证模型、hardware description、kernel 和 userspace

## Script Conventions

- 每个需要 repository root 路径的脚本使用以下形式：

  ```sh
  SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
  REPO_ROOT=$(git -C "${SCRIPT_DIR}" rev-parse --show-toplevel)
  ```

- 保持脚本精简，不添加环境中已具备命令的冗余检查
- arch 或 machine 专属路径直接放在对应 VM 的脚本中
- 代码注释使用简体中文，技术术语保留英文
- 中文注释不使用行尾句号
- 如果句子结尾是英文单词，使用英文句号，后续有文本时在句号后保留一个空格
- 不超过 100 个字符的说明保持单行

## VM-Specific Documentation

- 将 QEMU VM、CPU、kernel boot parameter、DTB、initramfs、PID 1 等约定写入
  对应 `vm/<arch>/<machine>/README.md`
- 某个 VM 的配置保持独立维护，不得成为其他架构或 machine 的隐式前提

## Verification

修改脚本或配置后，至少执行：

```sh
./vm/verify.sh
```

修改内容涉及构建或启动行为时，执行目标 VM 的 `build-all.sh` 后运行 QEMU，确认
其 README 规定的启动、设备和 userspace 行为正常工作
