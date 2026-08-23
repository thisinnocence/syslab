#!/bin/sh

export PATH=/sbin:/bin:/usr/sbin:/usr/bin
export PS1='[$PWD]# '

# 在运行时重新创建挂载点，打包 initramfs 时也会创建这些目录
# 即使 archive tool 丢弃空目录，/init 仍能正常工作
mkdir -p /dev /proc /sys /tmp

# 进入 userspace 前挂载 kernel pseudo-filesystems
# 随后检查特征文件，避免 /proc 挂载失败而未被发现
if [ ! -e /dev/null ]; then
    mount -t devtmpfs devtmpfs /dev || exec /bin/sh
fi

if [ ! -r /proc/self/stat ]; then
    mount -t proc proc /proc || exec /bin/sh
fi

if [ ! -d /sys/kernel ]; then
    mount -t sysfs sysfs /sys || exec /bin/sh
fi

if [ ! -r /proc/cpuinfo ]; then
    echo "ERROR: procfs is not available at /proc" >&2
    exec /bin/sh
fi

hostname riscv64-sifive-u
echo
echo "Welcome to the RISC-V sifive_u lab"
echo "Kernel: $(uname -r)"
echo "CPU(s): $(grep -c '^processor' /proc/cpuinfo)"
echo "procfs: mounted at /proc"
echo "Use Ctrl-a x to exit QEMU."
echo

# sifive_u 没有 shutdown device，所有关闭请求都通过 reboot 配合 QEMU
# -no-reboot 结束 emulator process
trap 'reboot -f' TERM
trap 'reboot -f' USR2
trap 'reboot -f' USR1

# 创建 session，并将 SiFive UART console 设为 controlling terminal，使交互 shell
# 获得正常的 job control
/usr/bin/setsid /bin/cttyhack /bin/sh &
wait "$!"

# PID 1 不能返回；用户退出交互 shell 后请求 reset，由 QEMU 正常退出
echo "Shell exited; stopping QEMU."
reboot -f
