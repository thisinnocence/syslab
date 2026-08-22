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

hostname aarch64-virt
echo
echo "Welcome to the AArch64 virt lab"
echo "Kernel: $(uname -r)"
echo "CPU(s): $(grep -c '^processor' /proc/cpuinfo)"
echo "procfs: mounted at /proc"
echo "Use Ctrl-a x to exit QEMU."
echo

# BusyBox 的 reboot、poweroff 和 halt 默认向 PID 1 发送信号
# PID 1 捕获信号后使用 -f 直接调用 kernel，分别执行 restart、poweroff 和 halt
trap 'reboot -f' TERM
trap 'poweroff -f' USR2
trap 'halt -f' USR1

# 创建 session，并将 PL011 console 设为 controlling terminal，使交互 shell
# 获得正常的 job control
/usr/bin/setsid /bin/cttyhack /bin/sh &
wait "$!"

# PID 1 不能返回；用户退出交互 shell 后正常关闭 guest
echo "Shell exited; powering off."
poweroff -f
