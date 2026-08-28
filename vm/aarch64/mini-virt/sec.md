# sec Device

sec 是 mini-virt 中的简单 XOR MMIO 设备，1 KB register 空间映射到
`0x0a000000-0x0a0003ff`。

| Register | Offset | Access | Description |
| --- | ---: | --- | --- |
| `DATA1` | `0x00` | RW | 第一个 U32 操作数 |
| `DATA2` | `0x04` | RW | 第二个 U32 操作数 |
| `CMD` | `0x08` | RW | 写 1 执行 XOR，写 0 清零结果 |
| `RESULT` | `0x0c` | RO | `DATA1 xor DATA2` 的 U32 结果 |

Linux driver 使用 DT compatible `syslab,sec` 匹配设备，并通过 platform
device 的 sysfs attribute 暴露四个 register。

## Driver Verification

在 repository root 构建并启动 mini-virt：

```sh
./vm/aarch64/mini-virt/build-all.sh
./vm/aarch64/mini-virt/run.sh
```

进入 BusyBox shell 后确认 driver 已完成 probe：

```sh
dmesg | grep sec
```

预期包含：

```text
syslab-sec a000000.sec: sec XOR device ready
```

initramfs 根目录包含静态链接的 driver 测试程序。默认 shell 路径为 `/`，
可以直接确认并执行：

```sh
ls -l sec.bin
./sec.bin
```

预期结果：

```text
sec test: PASS
```

`sec.bin` 会通过 sysfs 写入两个操作数，执行 XOR 并检查 `RESULT`，随后写
`CMD=0` 并检查结果已清零。程序返回 0 表示全部检查通过。

通过 sysfs 写入操作数并触发 XOR：

```sh
SEC=/sys/bus/platform/devices/a000000.sec

echo 0x12345678 > "$SEC/data1"
echo 0xa5a5ffff > "$SEC/data2"
echo 1 > "$SEC/cmd"
cat "$SEC/result"
```

预期结果：

```text
0xb791a987
```

验证清零命令：

```sh
echo 0 > "$SEC/cmd"
cat "$SEC/result"
```

预期结果：

```text
0x00000000
```

验证结束后关闭 guest：

```sh
poweroff
```
