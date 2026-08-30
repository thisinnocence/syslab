# sec Device

sec 是 mini-virt 中的简单 XOR MMIO 设备，1 KB register 空间映射到
`0x0a000000-0x0a0003ff`。

| Register | Offset | Access | Description |
| --- | ---: | --- | --- |
| `DATA1` | `0x00` | RW | 第一个 U32 操作数 |
| `DATA2` | `0x04` | RW | 第二个 U32 操作数 |
| `CMD` | `0x08` | RW | 写 1 执行 XOR，写 0 清零结果 |
| `RESULT` | `0x0c` | RO | `DATA1 xor DATA2` 的 U32 结果 |
| `IRQ_STATUS` | `0x10` | RW1C | bit 0 表示 IRQ pending，写 1 清除 |

## Interrupt Contract

### Interrupt Number

sec 使用 GICv3 SPI 2，即 PL011 UART 的 SPI 1 后一个中断号。GIC architecture 中
SGI 和 PPI 占用 INTID 0-31，因此 SPI 0 对应 INTID 32，sec 的 SPI 2 对应 INTID 34。

DT 中断描述为：

```dts
// DT SPI number 从 0 开始，Linux GIC domain 会加 32 转成硬件 INTID
// 此处 SPI 2 对应 GIC INTID 34，0x04 表示 level-high
interrupts = <0x00 0x02 0x04>;
```

三个 cell 的含义分别是：

| Cell | Value | Meaning |
| --- | ---: | --- |
| interrupt type | `0x00` | SPI |
| interrupt number | `0x02` | 从 0 开始编号的 SPI 2 |
| flags | `0x04` | level-high |

Linux GICv3 irqdomain 解析 DT 时执行 `hwirq = DT SPI number + 32`，因此得到硬件
INTID 34。Linux virtual IRQ 由 irqdomain 动态分配，例如验证时可能显示为 IRQ 14，
它不是 DT 中填写的 SPI number，也不要求每次启动保持不变。

### QEMU Wiring

sec device 在 instance initialization 中调用 `sysbus_init_irq()` 创建 anonymous IRQ
output 0。mini-virt machine 使用 `qdev_get_gpio_in()` 取得 GIC SPI 2 的 input sink，
再将它传给 `sysbus_create_simple()`。该 legacy helper 封装以下步骤：

1. 创建并 realize sec device。
2. 将 sec 的 MMIO region 0 映射到 `0x0a000000`。
3. 将 sec IRQ output 0 连接到传入的 GIC input sink。

`sysbus_create_simple()` 只负责创建、映射和连线，不决定中断何时触发。sec register
model 通过 `qemu_set_irq()` 控制 level-high 信号：

- 向 `CMD` 写 1：计算 XOR、置位 `IRQ_STATUS.bit0`、调用 `qemu_set_irq(..., 1)`。
- 向 `IRQ_STATUS.bit0` 写 1：按 W1C 语义清除 pending、调用
  `qemu_set_irq(..., 0)`。
- 向 `CMD` 写 0：只清零 `RESULT`，不产生中断。
- device reset：清除 pending 并撤销 IRQ。
- migration restore：根据迁移后的 `IRQ_STATUS` 恢复 IRQ level。

level interrupt 必须先清除设备侧 pending source 才会撤销。如果在前一次 pending 尚未
清除时直接再次写 `CMD=1`，IRQ line 已经处于 high，不会形成一个可区分的新事件。当前
Linux driver 通过同步完成每次命令，避免经由 `/dev/sec` 下发的连续命令被合并。

### Linux IRQ Handling

driver probe 按以下顺序建立中断链路：

1. 使用 `devm_platform_ioremap_resource()` 映射 sec register。
2. 使用 `platform_get_irq()` 将 DT interrupt specifier 映射为 Linux virtual IRQ。
3. 初始化 IRQ count 和 `completion`。
4. 使用 `devm_request_irq()` 注册 `sec_irq_handler()`。

硬件 IRQ handler 只能运行在内核态。hard IRQ context 不能睡眠，也不能直接调用
`copy_to_user()` 访问用户地址，因此 handler 不会直接执行用户态回调。sec handler 的处理
顺序是：

1. 读取 `IRQ_STATUS`；没有 pending 时返回 `IRQ_NONE`。
2. 读取 `RESULT`。
3. 向 `IRQ_STATUS.bit0` 写 1，清除设备侧 source 并撤销 level IRQ。
4. 增加 `irq_count`。
5. 打印 `[sec-irq]: result=...`。
6. 调用 `complete()` 唤醒等待本次命令的进程，并返回 `IRQ_HANDLED`。

### Event Delivery to Userspace

当前 ABI 使用 `completion` 将内核 IRQ 事件同步传递给发起命令的用户进程：

```text
userspace write()
        |
        v
sec_write(): reinit_completion() -> 写 DATA1/DATA2/CMD
        |
        v
wait_for_completion_timeout()，调用进程睡眠
        |
        v
QEMU sec 置 pending 并拉高 SPI 2
        |
        v
GICv3 -> Linux sec_irq_handler()
        |
        +-> 读取结果 -> W1C 清中断 -> irq_count++ -> complete()
                                                        |
                                                        v
                                        sec_write() 被唤醒并返回用户态
```

`sec_write()` 持有 transaction mutex，直到对应 handler 调用 `complete()`，因此同一时刻
只允许一条完整的 sec 命令。正常返回表示对应 IRQ 已经由 Linux handler 处理；超过 1 秒
仍未收到 IRQ 时返回 `-ETIMEDOUT`。

`SEC_IOC_GET_IRQ_COUNT` 返回 handler 已处理的累计中断次数。它用于测试中断前后 count
是否恰好增加 1，只提供当前计数快照，不是阻塞式事件通知接口。当前 driver 没有实现
`poll`、`epoll`、异步 `read`、`eventfd` 或 `SIGIO`；如果实验需要命令下发后继续执行其他
userspace 工作，应增加 wait queue 和 `.poll`，而不是循环查询 IRQ count。

## Userspace ABI

Linux driver 使用 DT compatible `syslab,sec` 匹配 platform device，并通过
miscdevice 框架创建 `/dev/sec` 字符设备。userspace ABI 定义在
`linux/include/uapi/linux/sec.h`：

| Operation | Buffer or command | Behavior |
| --- | --- | --- |
| `open` | `/dev/sec`，读写模式 | 打开设备 |
| `write` | `struct sec_operands`，两个 U32 | 执行 XOR，等待对应 IRQ handler 后返回 |
| `read` | 一个 U32 | 读取 `RESULT` |
| `ioctl` | `SEC_IOC_CLEAR` | 写 `CMD=0`，清零 `RESULT` |
| `ioctl` | `SEC_IOC_GET_IRQ_COUNT` | 获取 Linux driver 已处理的累计中断次数 |

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
sec irq test: PASS (count 0 -> 1)
sec test: PASS
0
```

`sec.bin` 会先读取 IRQ count，再通过 `write` 下发操作数和 CMD，并检查 IRQ count
恰好增加 1，从而确认 Linux handler 实际处理了中断。随后程序检查 XOR 结果，清零结果并
再次检查。程序返回 0 表示中断和 register 行为均通过。

还可以检查 handler 日志和 GIC 计数：

```sh
dmesg | grep '\[sec-irq\]'
cat /proc/interrupts | grep a000000.sec
```

预期日志包含：

```text
[sec-irq]: result=0xb791a987
```

`/proc/interrupts` 预期包含类似输出：

```text
14:          1          0     GICv3  34 Level     a000000.sec
```

第一列 `14` 是动态分配的 Linux virtual IRQ，`34` 是 GIC INTID，`Level` 是触发类型，
CPU count 是 handler 已处理的中断次数。再次执行 `sec.bin` 时，程序应显示 IRQ count
从 1 增加到 2，`/proc/interrupts` 中的 count 也应同步增加，从而验证每次 CMD 都对应
一次 handler 执行。

验证结束后关闭 guest：

```sh
poweroff
```
