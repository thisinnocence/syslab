# sec Device

sec 是 mini-virt 中的简单 XOR MMIO 设备，1 KB register 空间映射到
`0x0a000000-0x0a0003ff`。

| Register | Offset | Access | Description |
| --- | ---: | --- | --- |
| `DATA1` | `0x00` | RW | 第一个 U32 操作数 |
| `DATA2` | `0x04` | RW | 第二个 U32 操作数 |
| `CMD` | `0x08` | RW | 写 1 执行 XOR，写 0 清零结果 |
| `RESULT` | `0x0c` | RO | `DATA1 xor DATA2` 的 U32 结果 |

Linux driver 使用 DT compatible `syslab,sec` 匹配 platform device，并通过
miscdevice 框架创建 `/dev/sec` 字符设备。userspace ABI 定义在
`linux/include/uapi/linux/sec.h`：

| Operation | Buffer or command | Behavior |
| --- | --- | --- |
| `open` | `/dev/sec`，读写模式 | 打开设备 |
| `write` | `struct sec_operands`，两个 U32 | 写入操作数并执行 XOR |
| `read` | 一个 U32 | 读取 `RESULT` |
| `ioctl` | `SEC_IOC_CLEAR` | 写 `CMD=0`，清零 `RESULT` |

## Driver Verification

在 repository root 构建并启动 mini-virt：

```sh
./vm/aarch64/mini-virt/build-all.sh
./vm/aarch64/mini-virt/run.sh
```

进入 BusyBox shell 后确认 driver 已完成 probe，并创建字符设备：

```sh
dmesg | grep sec
ls -l /dev/sec
```

预期包含类似输出：

```text
syslab-sec a000000.sec: sec XOR character device ready
crw-------    1 0        0          10, ... /dev/sec
```

`tests/Makefile` 会静态链接 driver 测试程序，`build-initrd.sh` 将其安装到
initramfs 根目录。默认 shell 路径为 `/`，可以直接执行：

```sh
./sec.bin
echo $?
```

预期结果：

```text
sec test: PASS
0
```

`sec.bin` 会依次调用 `open`、`write`、`read` 和 `ioctl`：写入两个操作数，
检查 XOR 结果，清零结果并再次检查。程序返回 0 表示全部检查通过。

验证结束后关闭 guest：

```sh
poweroff
```
