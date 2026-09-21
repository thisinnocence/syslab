# PL011 UART：从硬件机制到 QEMU 与 Linux

本文围绕本仓库的 AArch64 `mini-virt` machine，解释一条字符怎样从 host 终端进入
QEMU 的 PL011 receive FIFO，经 GICv3 作为 SPI 送到 CPU，再由 Linux
`amba-pl011` driver 交给 TTY；发送方向则从 Linux console/TTY 写入 PL011 MMIO，最终
到达 QEMU chardev。重点不是罗列函数名，而是说明每层保存什么状态、由谁触发下一层，
以及真实 PL011 与当前 QEMU functional model 的边界。

本文对应的源码基线是当前 checkout：

- QEMU：`qemu/hw/arm/mini-virt.c`、`qemu/hw/char/pl011.c`、
  `qemu/include/hw/char/pl011.h`
- Linux：`linux/drivers/tty/serial/amba-pl011.c`、
  `linux/include/linux/amba/serial.h`
- DT：`linux/arch/arm64/boot/dts/demo/mini-virt.dts`
- 启动脚本：`vm/aarch64/mini-virt/run.sh`

硬件 programmer's model 以 Arm
[PrimeCell UART (PL011) Technical Reference Manual, DDI 0183](https://developer.arm.com/documentation/ddi0183/latest/)
为准。QEMU 和 Linux 源码是本文讨论“当前实现”的依据，不能用 TRM 中真实硬件的
timing 能力反推 QEMU 已经实现了相同 timing。

## 1. 先建立整体认识

UART 是把 CPU 一侧的并行字节转换成外部串行 bit stream 的设备。真实发送端会按
baud clock 依次输出 start bit、data bits、可选 parity bit 和 stop bit；接收端检测
start bit，在约定采样点恢复数据，检查 parity、framing、break 和 overrun，再将字符
放入 receive FIFO。

PL011 在这个基本 UART 上增加了：

- APB memory-mapped register interface
- 独立的 receive/transmit FIFO，标准 FIFO 深度为 16 entries
- integer/fractional baud-rate divider
- data bits、stop bits、parity、FIFO、break 和 flow-control 配置
- receive、transmit、receive-timeout、modem-status、error 等 interrupt source
- 单独 interrupt output 和把多个 source OR 在一起的 combined `UARTINTR`
- DMA request/control interface

在 mini-virt 中，完整路径可以先压缩成下面这张图：

```text
host terminal
    |
    | QEMU chardev byte/event
    v
CharBackend/CharFrontend
    |
    | pl011_receive()
    v
PL011State.read_fifo[]
    |
    | int_level & int_enabled
    v
PL011 combined IRQ output 0
    |
    | qemu_irq / GPIO level
    v
GICv3 SPI input 1 -> architectural INTID 33
    |
    | IRQ exception
    v
Linux GIC irqchip -> Linux virq 13（本次运行的动态编号）
    |
    | pl011_int()
    v
pl011_fifo_to_tty() -> tty flip buffer -> line discipline -> shell
```

发送方向不同：Linux 对 `UARTDR` 做 MMIO write 后，QEMU 当前实现直接调用
`qemu_chr_fe_write_all()` 把一个 byte 写给 host backend。它没有构造逐 bit 波形，也没有
根据 baud rate 等待一帧的传输时间。

## 2. 哪一层规定了什么

### 2.1 Arm architecture 没有规定 PL011 的 register offset

这里必须区分三个经常都被简称为“Arm 规范”的层次：

1. **Arm Architecture Reference Manual** 定义 AArch64 instruction、exception、
   memory type、load/store、system register 等 CPU architecture contract。它不规定系统
   必须包含 PL011，也不规定 `UARTDR` 必须位于 offset `0x000`。
2. **GIC architecture** 定义 SGI/PPI/SPI、INTID、priority、routing、acknowledge、EOI
   等 interrupt-controller contract。它不知道 INTID 33 后面接的是 PL011。
3. **PL011 TRM** 定义这个具体 peripheral IP 的 programmer's model，例如 register
   offset、bit field、FIFO、baud divider 和 interrupt output 语义。

所以“驱动看到一组固定 offset 就能适配”基本正确，但条件比一句话更多：设备必须真的
提供 PL011-compatible programmer's model，包括 register width/endian、PrimeCell ID、
clock、FIFO 和 interrupt semantics；platform 还必须把 MMIO、clock 和 IRQ 等 resource
准确描述给 OS。只复制几个 offset 而改变清中断或 FIFO 行为，并不构成可靠兼容。

### 2.2 TRM、SoC 集成和 DT 分工

PL011 TRM 定义相对于 peripheral base address 的 offset。SoC/board 决定 base address、
clock source、reset、interrupt-controller input 和 pinmux。mini-virt 的 DT 再把这些
platform resource 描述给 Linux：

```dts
apb-pclk {
        phandle = <0x8001>;
        clock-frequency = <0x16e3600>; /* 24,000,000 Hz */
        #clock-cells = <0>;
        compatible = "fixed-clock";
};

pl011@9000000 {
        clock-names = "apb_pclk";
        clocks = <0x8001>;
        interrupts = <0 1 4>;
        reg = <0 0x09000000 0 0x1000>;
        compatible = "arm,pl011", "arm,primecell";
};
```

`compatible` 表示软件可以按 PL011/PrimeCell contract 驱动；`reg` 给出物理 MMIO window；
`clocks` 给出 Linux 计算 baud divider 时看到的 clock；`interrupts` 描述 GIC SPI index 1、
level-high。它们缺一不可。

## 3. PL011 硬件机制

### 3.1 一帧 UART 数据

UART 没有伴随 data 的 clock wire，双方必须预先约定 baud rate 和 frame format。以
115200 8N1 为例，一帧通常是：

```text
idle=1  start=0  D0 D1 D2 D3 D4 D5 D6 D7  stop=1  idle=1
          <------------- 10 bit times ------------->
```

每秒 115200 symbols 时，一个 bit time 约为 8.68 us，一个 8N1 character 至少占 10 个
bit time，理论上限约 11520 bytes/s。真实硬件中的 TX FIFO 只是在 CPU burst write 与
逐帧移出之间解耦，不能消除 line rate。

RX 端持续观察输入线。发现 start bit 后按内部 oversampling clock 采样 data/parity/stop；
完成后把 data 和 error indication 放进 RX FIFO。若 FIFO 已满而又收到新字符，则产生
overrun。parity 不符产生 parity error，stop bit 不符合产生 framing error，输入长期保持
low 可形成 break。

### 3.2 核心寄存器

下面只列当前 QEMU/Linux 主路径会直接使用的寄存器。offset 和语义由 PL011 TRM 定义，
base address `0x09000000` 则由 mini-virt platform 定义。

| Offset | Register | 核心作用 |
| --- | --- | --- |
| `0x000` | `UARTDR` | write 进入 TX；read 取出 RX data，并带 error bits |
| `0x004` | `UARTRSR/UARTECR` | read receive error；write 清 error |
| `0x018` | `UARTFR` | `TXFE/TXFF/RXFE/RXFF/BUSY` 及 modem flags |
| `0x020` | `UARTILPR` | IrDA low-power counter，普通 UART 主路径不用 |
| `0x024` | `UARTIBRD` | integer baud divisor |
| `0x028` | `UARTFBRD` | 6-bit fractional baud divisor |
| `0x02c` | `UARTLCR_H` | word length、FIFO enable、stop/parity、break |
| `0x030` | `UARTCR` | UART/TX/RX/loopback/flow control enable |
| `0x034` | `UARTIFLS` | RX/TX FIFO interrupt threshold |
| `0x038` | `UARTIMSC` | interrupt mask；bit=1 表示允许该 source 输出 |
| `0x03c` | `UARTRIS` | raw interrupt status，不考虑 mask |
| `0x040` | `UARTMIS` | masked status，逻辑上是 `RIS & IMSC` |
| `0x044` | `UARTICR` | write-1-to-clear 对应 interrupt status |
| `0x048` | `UARTDMACR` | RX/TX DMA enable/control |
| `0xfe0..0xffc` | Peripheral/PrimeCell ID | AMBA discovery 和型号识别 |

CPU 访问的是 `base + offset`。例如 Linux read `UARTMIS`，最终访问的是 guest physical
address `0x09000040`；QEMU MemoryRegion 把它转换为该 device region 内 offset `0x40`。

### 3.3 波特率

标准 PL011 使用 UART reference clock `UARTCLK` 和 divisor：

```text
BRD       = IBRD + FBRD / 64
baud rate = UARTCLK / (16 * BRD)
```

Linux driver 把 divisor 放大 64 倍计算为 `quot`：

```c
quot = DIV_ROUND_CLOSEST(port->uartclk * 4, baud);
FBRD = quot & 0x3f;
IBRD = quot >> 6;
```

mini-virt DT 声明 `UARTCLK = 24 MHz`。本次启动中 driver 写了 `IBRD=39`、`FBRD=4`：

```text
BRD  = 39 + 4/64 = 39.0625
baud = 24,000,000 / (16 * 39.0625) = 38,400
```

这和没有显式 `console=ttyAMA0,<options>` 时本次 console 选择的 38400 相符。

`UARTLCR_H` 决定 5/6/7/8 data bits、one/two stop bits、parity 和 FIFO enable。真实线路的
两端若 baud 或 format 不一致，结果是乱码、framing/parity error 或根本无法识别数据。

### 3.4 FIFO 和 interrupt source

PL011 至少需要区分以下 interrupt source：

- RX：receive FIFO 达到配置 threshold
- TX：transmit FIFO 达到对应 empty threshold，需要软件继续填充
- RT：RX FIFO 非空但一段时间没有新字符，用 timeout 让不足 threshold 的尾部字符也被取走
- FE/PE/BE/OE：framing、parity、break、overrun error
- RI/CTS/DCD/DSR：modem signal change/status

`RIS` 表示 raw source state，`IMSC` 决定哪些 source 被允许送出，`MIS` 是软件看到的
masked result。抽象成逻辑就是：

```text
rx_condition ---- RIS.RX ---- IMSC.RX ----+
tx_condition ---- RIS.TX ---- IMSC.TX ----+
rt_condition ---- RIS.RT ---- IMSC.RT ----+--- OR ---> UARTINTR
error/status sources ----------------------+            combined pin
```

这里的 **mux/复用** 更准确地说是 interrupt aggregation：多个原因共用一根 combined
interrupt wire。CPU 收到这根线后必须读 `RIS/MIS` 找原因，逐项处理，直到所有 enabled
condition 都消失。

PL011 IP 还可以向 SoC 暴露 RX、TX、RT、modem 和 error 的独立 interrupt outputs。
platform 可以选择分别接线，也可以只接 combined output。mini-virt 只把 QEMU PL011 的
output 0，即 combined output，连接给 GIC。

### 3.5 level 还是 edge

mini-virt 的 UART interrupt 是 **active-high level SPI**，不是 edge：

- `interrupts = <0 1 4>` 中第一个 cell `0` 表示 GIC SPI
- 第二个 cell `1` 是 SPI index；GIC architectural INTID 为 `32 + 1 = 33`
- 第三个 cell `4` 是 `IRQ_TYPE_LEVEL_HIGH`

这和设备语义吻合：只要 `RIS & IMSC != 0`，combined output 就应保持 high。Linux 不能
只向 GIC EOI 就认为中断已经消失；还必须读 RX FIFO、停止/补充 TX，或向 `UARTICR`
清除相应 sticky status，使 device output deassert。若 source 仍在，GIC 会再次投递。

“适合回复 IRQ pin level”可以理解成：PL011 每次内部状态变化后都重新计算当前 pin
应为 0 还是 1，并把这个 **当前电平** 交给 interrupt controller，而不是只发一个瞬时
pulse。QEMU 的 `qemu_set_irq(irq, level)` 正好表达这个接口。

## 4. mini-virt 怎样实例化 PL011

### 4.1 machine resource contract

`qemu/hw/arm/mini-virt.c` 固定了：

```c
[VIRT_UART] = { 0x09000000, 0x00001000 };
[VIRT_UART] = 1; /* GIC SPI input index */
```

`mach_virt_init()` 的顺序是 CPU、RAM、GIC、UART、SMMU、SEC。GIC 必须先创建，因为
`create_uart()` 需要取得它的 input GPIO：

```c
DeviceState *dev = qdev_new(TYPE_PL011);
qdev_prop_set_chr(dev, "chardev", serial_hd(0));

SysBusDevice *s = SYS_BUS_DEVICE(dev);
sysbus_realize_and_unref(s, &error_fatal);
sysbus_mmio_map(s, 0, base);
sysbus_connect_irq(s, 0, qdev_get_gpio_in(vms->gic, irq));
```

这几步分别表示：

1. 用 QOM type `pl011` 分配 device object
2. 将 machine 的第一个 serial backend 绑定到它的 `chardev` property
3. realize，让 device 建立与 backend 的运行时关系
4. 把 SysBus MMIO region 0 映射到 system memory `0x09000000`
5. 把 SysBus IRQ output 0 接到 GIC input GPIO 1

`-nographic` 让默认 serial backend 使用当前 stdio，因此 host 键盘输入和 guest console
输出共享同一终端。chardev 是 byte-stream transport，不是 PL011 register model；PL011
model 才负责把 byte 放进 FIFO、暴露 MMIO status，并产生 IRQ。

### 4.2 为什么称为 SysBus device

QEMU `SysBusDevice` 是给 board-level、memory-mapped device 使用的基础类型。它不表示
guest 里真的存在一条名为“SysBus”的物理总线协议。PL011 object 通过：

```c
memory_region_init_io(..., &pl011_ops, ..., "pl011", 0x1000);
sysbus_init_mmio(sbd, &s->iomem);
for (i = 0; i < 6; i++)
        sysbus_init_irq(sbd, &s->irq[i]);
```

向 machine 暴露一个 4 KiB MMIO region 和六个 IRQ outputs。machine 负责选择 guest
physical address 和实际接哪一根 IRQ。这样 PL011 model 不需要知道 mini-virt、GIC
INTID 33 或 Linux virq。

### 4.3 MMIO dispatch

PL011 的 `MemoryRegionOps` 要求 4-byte access：

```c
static const MemoryRegionOps pl011_ops = {
        .read = pl011_read,
        .write = pl011_write,
        .endianness = DEVICE_NATIVE_ENDIAN,
        .impl.min_access_size = 4,
        .impl.max_access_size = 4,
};
```

guest 对 `0x09000000..0x09000fff` 的 load/store 经 QEMU address-space lookup 命中
`PL011State.iomem`，然后进入 `pl011_read()` 或 `pl011_write()`。两者以 `offset >> 2`
decode register。主要 state 对应关系是：

| Guest register | `PL011State` field |
| --- | --- |
| `UARTFR` | `flags` |
| `UARTRSR` | `rsr` |
| `UARTLCR_H` | `lcr` |
| `UARTCR` | `cr` |
| `UARTIBRD/FBRD` | `ibrd` / `fbrd` |
| `UARTIFLS` | `ifl`，但当前 RX threshold 实现没有按它工作 |
| `UARTIMSC` | `int_enabled` |
| `UARTRIS` | `int_level` |
| `UARTMIS` | `int_level & int_enabled` |
| RX FIFO | `read_fifo[]`、`read_pos`、`read_count` |
| IRQ pins | `qemu_irq irq[6]` |
| backend | `CharFrontend chr` |

这些 field 也大多进入 `vmstate_pl011`，用于 live migration 保存/恢复。register model 不只是
临时 callback；它是可迁移的 guest-visible device state。

## 5. QEMU 接收路径

### 5.1 realize 时安装 chardev callback

`pl011_realize()` 调用：

```c
qemu_chr_fe_set_handlers(&s->chr,
                         pl011_can_receive,
                         pl011_receive,
                         pl011_event,
                         NULL, s, NULL, true);
```

backend 在读取 host input 前先调用 `pl011_can_receive()` 查询剩余空间；有 byte 后调用
`pl011_receive()`；host break event 则走 `pl011_event()`。

`pl011_can_receive()` 返回 `fifo_depth - read_count`。但当前实现有一个明确兼容性放宽：
即使 `CR.UARTEN/RXE` 没开，也继续允许 backend 输入，因为历史 QEMU guest 可能依赖
UART 始终可收。这不是严格的真实 PL011 enable semantics。

### 5.2 byte 进入 FIFO

接收主路径是：

```text
host fd readable
  -> QEMU chardev backend read
  -> qemu_chr_be_write()
  -> pl011_receive(buf, size)
  -> 对每个 byte 调 pl011_fifo_rx_put()
       -> read_fifo[(read_pos + read_count) & (depth - 1)] = byte
       -> read_count++
       -> RXFE=0；满时 RXFF=1
       -> 达到 read_trigger 时 int_level |= INT_RX
       -> pl011_update()
```

FIFO disabled 时 depth 是 1，enabled 时为 16。标准硬件由 `UARTIFLS` 选择 threshold，
但当前 QEMU `pl011_set_read_trigger()` 把文档化的 threshold code 放在 `#if 0` 中，实际
总是 `read_trigger = 1`。因此 mini-virt 上任意第一个 pending byte 就产生 RX interrupt，
即使 Linux 向 `IFLS` 写了 1/2 FIFO threshold。

这是一处重要的 functional simplification：register 可读写，并不代表 threshold timing
已经按硬件实现。

### 5.3 guest 读 `UARTDR`

Linux read `UARTDR` 时，`pl011_read_rxdata()`：

1. 取 `read_fifo[read_pos]`
2. `read_count--`，环形推进 `read_pos`
3. 空时置 `RXFE`，先清 `RXFF`
4. 从 threshold 下降到 threshold 以下时清 `INT_RX`
5. 调 `pl011_update()` 重新计算 IRQ pins
6. 调 `qemu_chr_fe_accept_input()` 通知 backend 可以继续送数据

所以 RX interrupt 的自然 deassert 点不是 GIC EOI，而是 driver 把 FIFO 读到 threshold
以下，导致 PL011 model 清 RX raw condition 并重新输出 low。

### 5.4 receive timeout 的实现边界

当前 `pl011.c` 定义并路由了 `INT_RT`，Linux 也 enable `RTIM`，但 model 中没有根据
baud/frame idle time 安排 receive-timeout timer 的主路径。正常 host bytes 触发的是
`INT_RX`；不能因为 register bit 存在就认为 QEMU 已精确模拟硬件 RX timeout。

## 6. QEMU 发送路径

Linux console 或 TTY 最终 write `UARTDR`。QEMU 的路径是：

```text
guest store [0x09000000]
  -> memory_region dispatch
  -> pl011_write(offset=0)
  -> pl011_write_txdata(byte)
       -> qemu_chr_fe_write_all(&s->chr, &byte, 1)
       -> optional loopback into RX FIFO
       -> int_level |= INT_TX
       -> pl011_update()
```

几个实现细节很关键：

- `qemu_chr_fe_write_all()` 直接把 byte 交给 backend；源码注释明确指出它可能阻塞整个
  thread，并建议未来改成 background I/O callback
- model 不保存真正的 TX FIFO content，也不按 baud rate 定时逐 byte drain
- reset 后 `TXFE=1`，`TXFF=0`；正常输出中 Linux 几乎总能立即继续写
- 每次写 data 都置 `INT_TX`；Linux 在待发 ring buffer 为空时通过 mask TX interrupt
  停止继续触发
- loopback mode 也直接把 byte 放入 RX FIFO；源码明确说明没有模拟真实 TX FIFO 按
  frame rate 排空后再进入 RX logic 的过程

因此这个模型适合验证 register/driver/IRQ/console 的功能契约，不适合测吞吐、FIFO
backpressure、bit sampling、baud mismatch 或 line timing。

## 7. QEMU 中的 baud rate 到底有没有实质影响

### 7.1 结论

对当前 mini-virt + QEMU PL011 model，baud divider **主要是 guest-visible state 和 trace
信息，不控制字符的实际传输时间**。更严格地说：

- Linux 根据 DT 的 24 MHz clock 和 requested baud 计算 `IBRD/FBRD`
- QEMU 保存这些 register，migration 会携带它们，也能计算并 trace 一个 baud value
- 但 QEMU TX 直接同步写 chardev，RX 由 host backend 有 byte 时立即 push
- QEMU 没有按 baud 创建 TX/RX frame timer，也没有模拟串行 bit waveform
- Linux serial core 仍会用 baud 计算软件 timeout、drain interval 等，所以它并非对
  **所有软件** 都完全无意义

所以“只有软件可见而已”作为直觉基本成立，但最好表述成：**它不约束当前 emulated
data path 的物理时序；它仍影响 guest driver 的配置与部分软件时间估算，并作为 device
state 可见。**

### 7.2 mini-virt 还有一层 clock 接线缺口

本次 trace 暴露了更具体的问题。DT 向 Linux 声明了 24 MHz fixed clock，但
`create_uart()` 没有把一个 QEMU `Clock` 接到 `PL011State.clk`。启动时的 trace 是：

```text
pl011_write addr 0x028 value 0x00000004 reg FBRD
pl011_baudrate_change new baudrate 0 (clk: 0hz, ibrd: 0, fbrd: 4)
pl011_write addr 0x024 value 0x00000027 reg IBRD
pl011_baudrate_change new baudrate 0 (clk: 0hz, ibrd: 39, fbrd: 4)
pl011_write addr 0x02c value 0x00000070 reg LCRH
```

即 guest 配出了按 24 MHz 计算的 38400，但 QEMU device input clock 是 0 Hz，所以
`pl011_get_baudrate()` trace 结果为 0。串口仍正常完成 boot log、shell input 和 output，
正好证明当前 data path 没有使用该 baud 节流。

这是 DT hardware description 与 QEMU model wiring 不完全对称的地方：Linux 看见 clock，
QEMU device 没接 clock。若以后追求更完整模型，应让 machine 创建/连接对应 QEMU clock；
即使如此，仅连接 clock 仍不会自动获得 line timing，`pl011.c` 还需要用 timer/FIFO drain
机制真正消费 baud。

### 7.3 哪些实验不能用当前模型得结论

当前模型不能证明：

- 115200 比 9600 真实快 12 倍
- TX FIFO 在真实 line rate 下何时 full/empty
- 两端 baud 不匹配的误码行为
- parity/stop-bit sampling 的物理容差
- RX timeout 精确等于多少个 character time
- UART interrupt latency 或最大无丢失吞吐

它可以证明：register access、Linux driver binding、基本 FIFO bookkeeping、combined
level IRQ、GIC routing、TTY/console 数据流和 guest-visible配置是否闭环。

## 8. QEMU interrupt mux 和触发点

### 8.1 六个 QEMU output

`PL011State` 有 `qemu_irq irq[6]`，`irqmask[]` 定义每根 output 关心的 source：

| output | QEMU 注释名 | source mask |
| --- | --- | --- |
| 0 | `UARTINTR` combined | error、modem、RT、TX、RX |
| 1 | `UARTRXINTR` | RX |
| 2 | `UARTTXINTR` | TX |
| 3 | `UARTRTINTR` | RT |
| 4 | `UARTMSINTR` | modem status |
| 5 | `UARTEINTR` | errors |

mini-virt 只连接 output 0。其他五根在 device object 中存在，但没有接到 GIC，不能到达
guest。`sysbus_connect_irq(s, 0, ...)` 中的 `0` 是 PL011 output index；
`qdev_get_gpio_in(gic, 1)` 中的 `1` 是 GIC external input index。两者不要混淆。

### 8.2 `pl011_update()` 是 pin-level 汇合点

核心只有几行：

```c
flags = s->int_level & s->int_enabled;
for (i = 0; i < ARRAY_SIZE(s->irq); i++)
        qemu_set_irq(s->irq[i], (flags & irqmask[i]) != 0);
```

这里：

- `int_level` 对应 raw status/RIS
- `int_enabled` 对应 mask/IMSC
- `flags` 对应 MIS
- `irqmask[0]` 对 enabled sources 做 OR，形成 combined pin level
- `qemu_set_irq()` 把每根 wire 的当前 level 传播给 sink

调用 `pl011_update()` 的主要触发点是：

- RX FIFO 达到 trigger：set `INT_RX`
- read `UARTDR` 后低于 trigger：clear `INT_RX`
- write `UARTDR`：set `INT_TX`
- write `UARTIMSC`：mask 改变，立即重算
- write `UARTICR`：`int_level &= ~value`，立即重算
- loopback modem-control 改变：重算 modem source
- reset/load 等 state transition 相关路径

`qemu_set_irq()` 可以被重复调用为 1 或 0；它表达 wire state，不等于“一次调用就是一个
edge interrupt”。GIC 按 DT/guest programming 把 INTID 33 配成 level-high，并维护
pending/active/routing state。

### 8.3 source aggregation、GIC multiplexing 与 Linux shared IRQ

“中断复用”可能指三件不同的事：

1. PL011 内部多个 source 复用一个 combined pin：由 `irqmask[0]` OR 完成
2. GIC 把许多 device inputs 复用到少量 CPU IRQ exception lines：通过 INTID、priority、
   distributor/redistributor/CPU interface 仲裁，CPU acknowledge 后才知道具体 INTID
3. Linux `IRQF_SHARED` 允许多个 handler 注册同一 Linux IRQ：handler 必须读 device
   status 判断是不是自己的中断

mini-virt 当前 UART 物理连线没有和另一个设备共用 GIC SPI 1，但 driver 仍以
`IRQF_SHARED` request IRQ。PL011 内部 source aggregation 与 Linux shared-handler policy
不是同一件事。

## 9. Linux 怎样发现并初始化设备

### 9.1 从 DT 到 AMBA driver

DT 的 `arm,primecell` 使节点按 AMBA PrimeCell device 建立；MMIO 尾部的 peripheral/
PrimeCell ID 参与识别。QEMU `pl011_id_arm` 提供 PL011 ID。Linux 的 `pl011_ids[]` 与
`amba_driver pl011_driver` 完成匹配，进入 `pl011_probe()`。

probe 主路径是：

```text
DT / AMBA device
  -> pl011_probe()
       -> devm_clk_get()
       -> allocate struct uart_amba_port
       -> port.irq = dev->irq[0]
       -> port.ops = &amba_pl011_pops
       -> pl011_setup_port()
            -> devm_ioremap_resource()
            -> mapbase/membase/fifosize/line
       -> pl011_register_port()
            -> IMSC=0, ICR=0xffff
            -> uart_register_driver()（首次）
            -> uart_add_one_port()
```

`struct uart_amba_port` 是 PL011 driver 的中心对象，内嵌通用 serial core 的
`struct uart_port port`，再增加 `clk`、vendor register map、cached interrupt mask `im`、
DMA/RS485 state 等。`struct uart_driver amba_reg` 则定义 `ttyAMA` name、major/minor、
port 数和 console。

### 9.2 serial core 与 driver 的边界

TTY/serial core 管理 userspace API、termios、transmit ring buffer、line discipline、console
registration 和 generic locking contract；PL011 driver 通过 `uart_ops` 提供硬件动作：

- `startup/shutdown`
- `start_tx/stop_tx/stop_rx`
- `set_termios`
- `tx_empty`
- modem control
- console putchar/write/setup

因此 `/dev/ttyAMA0` write 不是直接调用 QEMU。数据先进入 serial core xmit buffer，再由
`pl011_start_tx()`/`pl011_tx_chars()` write MMIO；RX interrupt 则由 driver 把硬件字符
push 到 TTY flip buffer，之后 line discipline 和 reader 才消费。

### 9.3 startup 和 interrupt enable

port 被实际打开/启用时，`pl011_startup()`：

1. `pl011_hwinit()` enable/prepare clock
2. `pl011_allocate_irq()` 先写 cached `uap->im`，再
   `request_irq(..., pl011_int, IRQF_SHARED, "uart-pl011", uap)`
3. 写 `UARTIFLS`
4. 写 `UARTCR`，enable UART、RX 和通常的 TX
5. 初始化 DMA；mini-virt 没有 DT DMA channel，实际退回 PIO
6. `pl011_enable_interrupts()` 清 RX/RT，drain 旧 FIFO，再 enable `RTIM|RXIM`

本次正常状态下 QEMU trace 多次看到：

```text
pl011_write addr 0x038 value 0x00000050 reg IMSC
```

`0x50 = RTIM(bit 6) | RXIM(bit 4)`。QEMU 实际实现 RX source，RT bit 虽被 enable 但没有
完整 timeout timer。

## 10. Linux baud、console 与正常 TX

### 10.1 `pl011_set_termios()`

termios 改变时，driver：

1. `uart_get_baud_rate()` 选择合法 baud
2. 根据 `port->uartclk` 算放大 64 倍的 divisor `quot`
3. 根据 `CS5..CS8`、`CSTOPB`、`PARENB/PARODD` 生成 `LCR_H`
4. 调 `uart_update_timeout()` 更新 serial core software timeout
5. 配置 status/error mask 和 flow control
6. 依次写 FBRD、IBRD，再写 LCR_H，最后确保 RX enable

驱动特意要求 LCR_H 在 divisor 后写，这是 PL011 programmer's model 的 latch/update
顺序要求。驱动能复用的根本原因不是设备名字相同，而是这些 register semantics 相同。

### 10.2 earlycon、console 和普通 TTY

mini-virt command line 是：

```text
console=ttyAMA0 earlycon=pl011,0x09000000 rdinit=/init panic=-1
```

启动分三阶段理解：

- earlycon 很早只知道 PL011 type 和 physical address，主要用 polling write 输出
- 正式 `amba-pl011` probe 后注册 `ttyAMA0`
- console handover 后 `console=ttyAMA0` 使用正式 driver；userspace shell 也从该 TTY 读写

earlycon 能打印只证明 MMIO TX polling path 可用，不能单独证明 DT interrupt、GIC routing
或 `pl011_int()` 正常。本文用 `/proc/interrupts` 和 RX trace 另外验证 IRQ。

console write 的核心是 `pl011_console_write()` 调 generic `uart_console_write()`；后者逐字符
调用 `pl011_console_putchar()`，等待 `TXFF` 清零后写 `DR`。当前 QEMU `TXFF` 通常不置位，
所以这个 polling 很快通过。

普通 TTY TX 走：

```text
write(fd=/dev/ttyAMA0)
  -> TTY/serial core xmit ring
  -> uart_ops.start_tx = pl011_start_tx
  -> no DMA -> pl011_start_tx_pio
  -> pl011_tx_chars(from_irq=false)
  -> pl011_tx_char
  -> writel(byte, UARTDR)
  -> QEMU pl011_write_txdata
  -> host chardev
```

TX interrupt path用于继续 drain xmit ring。ring 为空时 `pl011_stop_tx()` mask TX interrupt，
否则一个 permanently asserted TX condition 会造成 interrupt storm。

## 11. Linux RX interrupt 执行流

### 11.1 top-level handler

GIC 投递 INTID 33 后，Linux irq subsystem 调 `pl011_int()`。核心逻辑是：

```c
status = pl011_read(uap, REG_RIS) & uap->im;
do {
        pl011_write(status & ~(TXIS | RTIS | RXIS), REG_ICR);
        if (status & (RTIS | RXIS))
                pl011_rx_chars(uap);
        if (status & modem_bits)
                pl011_modem_status(uap);
        if (status & TXIS)
                pl011_tx_chars(uap, true);
        status = pl011_read(uap, REG_RIS) & uap->im;
} while (status != 0 && pass_counter_not_exhausted);
```

它读取 `RIS & cached IMSC` 而不是只信 Linux IRQ number，因为 combined wire 可能同时有
多个 reason。handler 循环到状态清空，并用 `AMBA_ISR_PASS_LIMIT` 防止坏设备或未消除
condition 把 CPU 永久困在 hardirq。

注意 RX/TX/RT 没有在第一笔 ICR write 中直接 clear；driver 通过读 FIFO或处理 TX
condition 消除它们。其他 sticky source 则 write-1-to-clear。

### 11.2 FIFO 到 TTY

`pl011_rx_chars()` 调 `pl011_fifo_to_tty()`，后者循环：

1. read `UARTFR`，若 `RXFE` 则结束
2. read `UARTDR`，取得 byte 和 error bits
3. 更新 `port.icount`
4. 处理 break/sysrq/parity/framing/overrun policy
5. `uart_insert_char()` 放入 TTY flip buffer

随后 driver 暂时释放 port lock，调用 `tty_flip_buffer_push()` 把 batch 提交给 TTY layer，
再重新加锁。shell 最终读到的是 line discipline 处理后的字符，不是直接读取 MMIO。

### 11.3 一次 RX 的 level 生命周期

```text
host 输入 'c'
  QEMU pl011_fifo_rx_put
    read_count: 0 -> 1
    int_level |= INT_RX
    pl011_update: combined pin = 1
      GIC SPI1 pending -> INTID 33
        CPU IRQ -> Linux pl011_int
          read RIS & im: RX
          read FR / read DR
            QEMU read_count: 1 -> 0
            int_level &= ~INT_RX
            pl011_update: combined pin = 0
          tty_flip_buffer_push
        GIC EOI/deactivate
```

GIC acknowledge/EOI 管理的是 interrupt-controller 中的 pending/active state；read DR
改变的是 peripheral source 和 wire level。两者都需要，顺序也由 Linux irq flow 与 handler
共同完成。

## 12. 本次 mini-virt 运行证据

### 12.1 构建与边界

本次先在 active profile 为 `aarch64/mini-virt` 的 `qemu/build` 上执行增量
`vm/aarch64/mini-virt/build-qemu.sh`，再用当前 Image、DTB 和 initramfs 启动。QEMU trace
启用了 `pl011_*`。trace 会显著增加输出量，适合证明调用/状态顺序，不用于测性能。

启动日志确认：

```text
earlycon: pl11 at MMIO 0x0000000009000000
Serial: AMBA PL011 UART driver
9000000.pl011: ttyAMA0 at MMIO 0x9000000 (irq = 13, base_baud = 0) is a PL011 rev1
printk: legacy console [ttyAMA0] enabled
printk: legacy bootconsole [pl11] disabled
```

Linux virq 13 是本次运行动态分配的编号，不是 DT 或硬件 ABI。固定的是 GIC INTID 33。
日志中的 `base_baud = 0` 也不应被误读为串口不能工作；本次实际 console 正常，而 QEMU
clock input 未连接的问题已由 QEMU trace 直接确认。

### 12.2 输入、FIFO 和 level assertion

在 guest prompt 输入 `cat /proc/interrupts` 时，trace 开头是：

```text
pl011_can_receive LCR 0x70, RX FIFO used 0/16, can_receive 16 chars
pl011_receive recv 1 chars
pl011_fifo_rx_put RX FIFO push char [0x63] 1/16 depth used
pl011_irq_state irq state 1
pl011_can_receive LCR 0x70, RX FIFO used 1/16, can_receive 15 chars
pl011_receive recv 1 chars
pl011_fifo_rx_put RX FIFO push char [0x61] 2/16 depth used
```

`0x63` 是 `c`，`0x61` 是 `a`。这证明 host input 先成为 chardev byte，再进入 QEMU
FIFO；第一个 byte 就使 combined IRQ high，也实证了当前 model 的 RX trigger 为 1，而非
Linux 写入的 FIFO fraction。

### 12.3 `/proc/interrupts`

同一次运行读到：

```text
           CPU0       CPU1
 10:       3758       3733     GICv3  30 Level     arch_timer
 13:          1          0     GICv3  33 Level     uart-pl011
```

它同时验证：

- PL011 已注册 `uart-pl011` handler
- hwirq/INTID 是 33
- Linux irqchip 将其配置/显示为 `Level`
- 至少一次输入经 IRQ handler 处理

计数为 1 不表示只输入了一个字符。host backend 可以在一次 IRQ assert 期间继续填多个
byte，handler 又会在一次 invocation 中 drain FIFO；level IRQ 计数的是 handler delivery，
不是 byte 数。

### 12.4 host GDB backtrace：从 chardev 到 GIC

当前 checkout 的 debug QEMU 对 UART input assertion 捕获到下面的 host stack；这是
QEMU 进程栈，不是 guest kernel stack：

```text
#0  gicv3_set_irq(opaque=..., irq=1, level=1)
#1  qemu_set_irq(irq=..., level=1)
#2  pl011_update(s=...)
#3  pl011_fifo_rx_put(opaque=..., value=99)
#4  pl011_receive(opaque=..., buf=..., size=16)
#5  qemu_chr_be_write_impl(...)
#6  qemu_chr_be_write(...)
#7  tcp_chr_read(...)
#8  qio_channel_fd_source_dispatch(...)
```

该次 GDB 采集使用 Unix socket chardev，因此 backend frame 是 `tcp_chr_read()`；本次本文
trace 运行使用 `-nographic` stdio，但从 `pl011_receive()` 向下的 device/GIC 路径相同。
`value=99` 即 ASCII `c`。`irq=1` 是进入 GIC model 的 external input index，
`gicv3_set_irq()` 的 SPI 分支再把它解释成 INTID 33。

断点时可观察的关键 `PL011State` 应按下面方式解释：

```text
s->read_count          RX FIFO 当前占用
s->read_pos            下一次 DR read 的位置
s->read_trigger        当前 QEMU 实现为 1
s->int_level           RIS/raw sources
s->int_enabled         IMSC/mask
s->int_level &
  s->int_enabled       MIS/combined decision 的输入
s->irq[0]              已接到 GIC SPI1 sink 的 combined output handle
s->ibrd / s->fbrd      guest-visible baud divisor
clock_get_hz(s->clk)   当前 mini-virt 为 0
```

GDB 暂停所有 QEMU threads 会扰动虚拟时间和 I/O scheduling，所以该栈证明调用关系、
状态和接线，不证明真实 interrupt latency。

## 13. 当前模型与真实 PL011 的差异清单

| 能力 | 真实 PL011 | 当前 QEMU/mini-virt |
| --- | --- | --- |
| MMIO register map | TRM 定义 | 主寄存器已实现，4-byte access |
| RX FIFO | 16-entry，threshold 可配 | 16-entry，但 RX trigger 固定为 1 |
| TX FIFO | 按 line rate drain | 没有真实 byte queue/timed drain |
| baud divider | 控制 bit timing | 保存/trace，不控制 chardev timing |
| UART input clock | platform 必须提供 | DT 给 Linux 24 MHz，QEMU Clock 未连接 |
| RX timeout | 按 idle/frame timing 产生 | status bit/path存在，未见完整 timer 主路径 |
| frame sampling/error | start/data/parity/stop 采样 | host 直接提供 byte；仅有限 error/break event 表示 |
| enable semantics | UARTEN/RXE/TXE 控制数据通路 | RX 为兼容历史 guest，未严格检查 enable |
| DMA | PL011 有 DMA request/control | 写 enable 会报告 `DMA not implemented` |
| combined/individual IRQ | 都可供 SoC 集成 | 六根 output 均建模，仅 combined 接入 mini-virt |
| loopback | serial-bit path | byte 级立即回灌，源码明确标注简化 |

理解这张表，才能正确选择验证目标：QEMU 是很好的 software-visible functional model，
不是 UART PHY、RTL timing 或 performance simulator。

## 14. 调试方法

### 14.1 QEMU trace

在 repository root 可以直接启动带 PL011 trace 的完整 profile artifact：

```sh
qemu/build/qemu-system-aarch64 \
  -machine mini-virt -smp 2 -m 4G -nographic \
  -kernel linux/build/arch/arm64/boot/Image \
  -dtb linux/build/arch/arm64/boot/dts/demo/mini-virt.dtb \
  -initrd busybox/build/initramfs.cpio.gz \
  -append 'console=ttyAMA0 earlycon=pl011,0x09000000 rdinit=/init panic=-1' \
  -trace 'enable=pl011_*' \
  -trace file=/tmp/mini-virt-uart.trace
```

常用筛选：

```sh
rg 'baudrate|can_receive|receive|fifo_rx_put|read_fifo|irq_state' \
  /tmp/mini-virt-uart.trace
```

trace 中 earlycon/console 的每字符 MMIO 很多，观察 RX 最好用一个短而唯一的 marker，
并同时记录 FIFO occupancy 和 IRQ level，不能只搜索某个 data byte。

### 14.2 host GDB 断点

适合分别捕获：

```text
pl011_receive              chardev 向 device 交数据
pl011_fifo_rx_put          FIFO/status 更新
pl011_update               source/mask 到 pin level
gicv3_set_irq if irq == 1  UART wire 进入 GIC
pl011_read_rxdata          guest drain FIFO/deassert
pl011_write_txdata         guest TX 到 chardev
```

对 `pl011_update()` 最有用的状态不是只看 stack，而是同时 print：

```gdb
p/x s->int_level
p/x s->int_enabled
p s->read_count
p s->read_trigger
p s->ibrd
p s->fbrd
p clock_get_hz(s->clk)
```

若要看 Linux guest stack，则应使用 QEMU gdbstub、guest symbols 和合适的 kernel debug
配置；host GDB 的 `pl011_*` stack 无法显示 guest `pl011_int()`，两者是不同执行环境。

### 14.3 guest 侧检查

```sh
cat /proc/interrupts
cat /proc/tty/driver/serial
```

重点检查 `uart-pl011` 对应的 GIC hwirq 33、trigger type `Level` 和输入前后的计数变化。
不要把 Linux virq 数字写成固定 ABI，也不要用 boot log 存在替代 RX interrupt 验证。

## 15. 总结

PL011 compatibility 是一组跨层 contract：TRM 定义 register/FIFO/interrupt programmer's
model；machine 把 device 映射到地址并连接 clock、chardev 和 GIC；DT 把 resource 告诉
Linux；`amba-pl011` driver 通过 serial core 把它变成 console 和 `ttyAMA0`。

mini-virt 的具体闭环是：

```text
MMIO 0x09000000, size 0x1000
PL011 combined output 0
GIC SPI index 1 / INTID 33 / level-high
Linux amba-pl011 / ttyAMA0 / 本次 virq 13
```

RX 中断是 level contract：QEMU 以 `int_level & int_enabled` 计算 pin，Linux 读 FIFO 或清
status 消除 source，GIC EOI 只处理 controller state。PL011 内部多个 reason 在 combined
pin 上聚合，Linux handler 必须读 status demux。

波特率方面，guest driver 确实按 DT 24 MHz 配置了 divisor，但当前 mini-virt 没把 QEMU
clock 接给 PL011，且 QEMU PL011 data path 本来也没有按 baud 做逐帧 timing。因而本模型
能验证软件可见的 UART 功能链路，不能代表真实串行线的 timing、误码和吞吐。
