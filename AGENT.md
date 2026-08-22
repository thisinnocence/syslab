# Syslab Agent 指引

## Repository 结构

- `qemu/`、`linux/`、`busybox/` 是 Git submodule
- `vm/<arch>/<machine>/` 保存某个 arch 和 VM 的构建、启动脚本及说明文档

## 构建约定

- 每个 submodule 的 build output 只能放在其自身的 `build/` 目录
- 一个具体 VM 是一个 build object，独占 `qemu/build`、`linux/build` 和 `busybox/build`
- build object 或 configure-time 选项变更时，清空这三个 build 目录后重新构建
- 在目标 VM 目录中使用 `build-all.sh` 构建全部组件，并使用 `run.sh` 启动 QEMU

## 脚本约定

- 每个需要 repository root 的脚本使用以下形式：

  ```sh
  SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
  REPO_ROOT=$(git -C "${SCRIPT_DIR}" rev-parse --show-toplevel)
  ```

- 保持脚本精简，不添加环境中已具备命令的冗余检查
- arch 或 machine 专属路径直接放在对应 VM 的脚本中，不抽到伪通用变量或公共文件
- 代码注释使用简体中文，技术术语保留英文
- 中文注释不使用行尾句号
- 不超过 100 个字符的说明保持单行

## VM 专属说明

- 将 QEMU machine、CPU、kernel boot parameter、DTB、initramfs、PID 1 等约定写入
  对应 `vm/<arch>/<machine>/README.md`
- 某个 VM 的配置不得成为其他架构或 machine 的隐式前提

## 验证

修改脚本或配置后，至少执行：

```sh
bash -n vm/<arch>/<machine>/*.sh
[ ! -f vm/<arch>/<machine>/init.sh ] || sh -n vm/<arch>/<machine>/init.sh
git diff --check
```

涉及构建或启动行为时，执行目标 VM 的 `build-all.sh` 后运行 QEMU，确认其 README
规定的启动、设备和 userspace 行为正常工作
