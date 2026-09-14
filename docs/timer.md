# ARM Generic Timer：体系结构、QEMU 仿真与 Linux 实现

本文以 syslab 当前 checkout 的 `aarch64/mini-virt` 为实验对象，分析 ARM Generic
Timer（通用定时器）的硬件语义、QEMU TCG 如何用 host timer 仿真这些语义，以及
Linux 如何把它注册成 clocksource（时钟源）和 clock event device（时钟事件设备）。

本文使用的版本是：

- syslab `93dc0259a1d5`
- QEMU 10.2.0，`a5ed11b21a9f`
- Linux 6.9，`31e35d15d55a`
- machine `mini-virt`，`-cpu cortex-a57`，2 个 vCPU，TCG MTTCG
- Linux `CONFIG_HZ=250`、`CONFIG_HZ_PERIODIC=y`、`CONFIG_HIGH_RES_TIMERS=n`

先给出贯穿全文的结论：

1. Generic Timer 不是一个周期性递减到零的独立硬件计数器。系统中有一个持续递增的
   system counter；每个 PE 上的 timer 保存 compare value，并比较
   `Count - Offset >= CVAL`。`TVAL` 只是这个 compare value 的 32-bit 相对时间视图。
2. QEMU 不逐 tick 模拟 62.5 MHz counter。它按需用 `QEMU_CLOCK_VIRTUAL` 计算当前
   counter，并把最近一次 compare deadline 放入 host 的有序 `QEMUTimer` 队列。到期后
   callback 重新计算 `ISTATUS`，再通过 GPIO 把 level-high PPI 送进 GICv3。
3. 当前 mini-virt 的 Linux 选择 non-secure physical timer：读取 `CNTPCT_EL0` 作为
   clocksource，使用每 CPU 的 `CNTP_CVAL_EL0/CNTP_CTL_EL0` 产生 PPI 30。timer IRQ
   handler 先置 `IMASK` 撤销 level IRQ，再由 generic tick 层安排下一个 deadline。

这三层可以先压缩成一条路径：

```text
Linux 写 CNTP_CVAL_EL0 / CNTP_CTL_EL0
  -> TCG system-register helper
  -> QEMU ARMGenericTimer.cval / ctl
  -> gt_recalc_timer()
  -> QEMUTimer 按 QEMU_CLOCK_VIRTUAL deadline 排队
  -> arm_gt_ptimer_cb()
  -> ISTATUS=1, qemu_set_irq(level=1)
  -> GICv3 CPU-local PPI 30
  -> AArch64 IRQ exception
  -> Linux gic_handle_irq()
  -> arch_timer_handler_phys()
  -> IMASK=1, tick_handle_periodic()
  -> 写下一次 CVAL, IMASK=0
```

## 1. ARM 体系结构：counter、timer 和 interrupt 是三件事

### 1.1 System counter 提供统一时间基准

ARM Generic Timer 的底层是 system counter。它以固定频率递增，并向系统中的 PE
分发一致的 count value。软件通过 `CNTFRQ_EL0` 得到名义频率，通过 `CNTPCT_EL0`
读取 physical count。

`CNTFRQ_EL0` 描述频率，不是控制计数速度的分频寄存器。真实 SoC 通常由 secure
firmware 在启动早期配置 memory-mapped system counter control frame；OS 读取 PE
上的 system register view。当前 mini-virt 没有单独仿真 `CNTControlBase` 或
`CNTReadBase` MMIO frame，只提供 QEMU ARM CPU 内建的 system-register interface。

以本实验的 62.5 MHz 为例：

```text
frequency = 62,500,000 tick/s
period    = 1,000,000,000 ns / 62,500,000 = 16 ns/tick
```

因此 guest 看到的 count 每 16 ns 增加 1。这里的 16 ns 是 architected counter 的
分辨率，不表示 QEMU 每 16 ns 执行一次 callback，也不表示 Cortex-A57 指令周期是
16 ns。

Arm 官方学习文档把 system counter 和每个 PE 的 timer 分开描述：

- [Learn the architecture: Generic Timer, document 102379][arm-generic-timer]
- [Arm Architecture Reference Manual for A-profile, DDI 0487](https://developer.arm.com/documentation/ddi0487/latest)

[arm-generic-timer]: https://documentation-service.arm.com/static/65fac6957bcc0c1c661b36c0

### 1.2 每个 PE 有多组 timer

System counter 是全局时间基准，timer interface 则是 per-PE 的。A-profile 架构按
Exception Level 和 physical/virtual time 提供多组 timer。QEMU 当前用如下索引表达：

| QEMU index | AArch64 register 前缀 | 主要用途 | 架构中断 INTID |
| --- | --- | --- | --- |
| `GTIMER_PHYS=0` | `CNTP_*` | Non-secure EL1 physical timer | 30 |
| `GTIMER_VIRT=1` | `CNTV_*` | EL1 virtual timer | 27 |
| `GTIMER_HYP=2` | `CNTHP_*` | Non-secure EL2 physical timer | 26 |
| `GTIMER_SEC=3` | `CNTPS_*` | Secure EL1 physical timer | 29 |
| `GTIMER_HYPVIRT=4` | `CNTHV_*` | VHE EL2 virtual timer | 28 |
| `GTIMER_S_EL2_PHYS=5` | `CNTHPS_*` | Secure EL2 physical timer | 20 |
| `GTIMER_S_EL2_VIRT=6` | `CNTHVS_*` | Secure EL2 virtual timer | 19 |

不是每种 CPU、security configuration 或 Exception Level 都能访问所有接口。访问是否
允许还受 `CNTKCTL_EL1`、`CNTHCTL_EL2`、`HCR_EL2`、`SCR_EL3` 等寄存器控制；禁止的
访问会 trap 到更高 EL 或产生 Undefined Instruction。QEMU 在
`gt_counter_access()` 和 `gt_timer_access()` 中实现这部分权限检查。

当前 mini-virt 真正使用的是第一行。Linux 启动日志中的 `(phys)` 指 physical timer
interface，并不表示 QEMU 把它实现成一个 MMIO 外设；guest 仍然使用 `MRS/MSR`
访问 system register。

### 1.3 Physical count 与 virtual count

Virtual count 的基本关系是：

```text
CNTVCT_EL0 = physical count - CNTVOFF_EL2
```

hypervisor 在切换 VM 时改变 `CNTVOFF_EL2`，guest 就能得到自己的时间轴，而不必修改
底层 system counter。physical timer 比较 physical count；virtual timer 比较减去
offset 后的 virtual count。

这也是 Linux 在 EL2 可用时倾向给 host kernel 使用 physical timer、把 virtual timer
留给虚拟机的原因。当前 Linux 的 `arch_timer_select_ppi()` 逻辑是：

```text
kernel 本身运行在 EL2        -> EL2 physical timer
EL2 不可用且 virtual PPI 存在 -> EL1 virtual timer
arm64 的普通 EL1 host        -> non-secure EL1 physical timer
```

mini-virt 的 kernel 启动时报告 `All CPU(s) started at EL2`，并保留了 EL2 能力；最终
timer driver 选择 non-secure physical PPI，所以日志为 `(phys)`。

### 1.4 CVAL、TVAL 与 CTL

每组 timer 的核心状态可以理解为一个 64-bit compare value 和一个控制寄存器：

```text
effective count = Count - Offset
timer condition = effective count >= CVAL
```

计数和差值遵循相应寄存器宽度的 wraparound 规则。QEMU 对应代码刻意使用 unsigned
64-bit arithmetic：

```c
int istatus = count - offset >= gt->cval;
```

软件有两种方式设置同一个 deadline：

| 寄存器 | 宽度 | 含义 | 写入效果 |
| --- | --- | --- | --- |
| `CNTx_CVAL` | 64 bit | absolute compare value | `CVAL = value` |
| `CNTx_TVAL` | 32 bit signed | 从当前 count 起的相对 tick 数 | `CVAL = Count - Offset + sign_extend(TVAL)` |

`TVAL` 看起来像递减计数器，实际可以随时由 `CVAL - current count` 计算出来。QEMU
因此只保存 `cval`，没有保存一个需要逐 tick 递减的 `tval` 字段。

`CNTx_CTL` 的低三位是：

| bit | 名称 | 作用 |
| --- | --- | --- |
| 0 | `ENABLE` | 允许 timer condition 参与输出；清零时 `ISTATUS` 和输出均为 0 |
| 1 | `IMASK` | 屏蔽 interrupt output，不阻止 condition 形成 |
| 2 | `ISTATUS` | timer condition 状态；在 timer disable 时读为 0 |

中断输出条件为：

```text
IRQ = ENABLE && ISTATUS && !IMASK
```

这是 level signal。timer 到期以后，仅仅在 GIC 中 EOI 并不能消除源头电平。软件必须
设置未来的 `CVAL/TVAL`、置 `IMASK`，或清 `ENABLE`。Linux handler 先置 `IMASK`，正是
为了在处理到期事件时立即撤销 timer 输出。

### 1.5 timer PPI 的硬件含义

Generic Timer interrupt 是 PPI（Private Peripheral Interrupt），即每个 PE 私有的
中断。相同的 INTID 30 在 CPU0 和 CPU1 上有各自的 pending/active 状态，不是一个
共享 SPI。

mini-virt DT 的编码如下：

```dts
timer {
    interrupts = <1 13 4>,  // PPI 13 + 16 = INTID 29, secure physical
                 <1 14 4>,  // PPI 14 + 16 = INTID 30, non-secure physical
                 <1 11 4>,  // PPI 11 + 16 = INTID 27, virtual
                 <1 10 4>;  // PPI 10 + 16 = INTID 26, hypervisor
    compatible = "arm,armv8-timer";
};
```

第一个 cell `1` 表示 PPI，第二个 cell 是从 16 开始计算前的 PPI number，第三个
cell `4` 表示 level-high。该顺序由 Linux binding 定义，参见当前 kernel tree 的
`Documentation/devicetree/bindings/timer/arm,arch_timer.yaml`，以及
[upstream binding](https://www.kernel.org/doc/Documentation/devicetree/bindings/timer/arm%2Carch_timer.yaml)。

## 2. mini-virt 的实现边界

### 2.1 CPU、timer 和 GIC 的实际连线

`mini-virt` 的 `mach_virt_init()` 先创建两个 Cortex-A57 CPU，再创建 GICv3。
`arm_cpu_initfn()` 为每个 CPU 建立 7 个 generic timer GPIO output；CPU realize 时
再为每组 timer 创建一个 `QEMUTimer`。

当前 machine 的 timer 连线只有一条：

```c
int intidbase = NUM_IRQS + i * GIC_INTERNAL;
qdev_connect_gpio_out(cpudev, 0,
    qdev_get_gpio_in(vms->gic,
        intidbase + ARCH_TIMER_NS_EL1_IRQ));
```

这里：

```text
CPU GPIO output 0 = GTIMER_PHYS
NUM_IRQS           = 256
GIC_INTERNAL       = 32
CPU0 GPIO input    = 256 + 0 * 32 + 30 = 286
CPU1 GPIO input    = 256 + 1 * 32 + 30 = 318
最终 architectural INTID = 30
```

GIC 的 GPIO input number 不是最终 INTID。`gicv3_set_irq()` 看到 input 286 后先减去
SPI input count 256，得到 CPU0 的 PPI 30，再调用 `gicv3_redist_set_irq()` 更新 CPU0
redistributor。

### 2.2 DT 声明与 machine 连线并不完全对称

DT 声明了四个常见 PPI，但当前 mini-virt 只连接 `gt_timer_outputs[0]`，即 physical
timer。QEMU ARM CPU model 已实现另外六组 timer，DT 也给 Linux 描述了 virtual、
secure 和 hypervisor PPI，但那些输出没有在此 machine 中接到 GIC。

当前实验仍能正常工作，因为 Linux 恰好选择 physical timer。这个结论的适用边界是：

- 当前 host Linux 的 clocksource/clockevent 路径可用
- 两个 vCPU 的 PPI 30 都已连接并有运行时中断
- 不能据此声称 mini-virt 的 virtual/hypervisor/secure timer interrupt 路径可用
- 若在 mini-virt 内运行 KVM guest，或改变 boot EL 使 Linux 选择 virtual timer，
  必须先补齐对应 `gt_timer_outputs[] -> GIC PPI` 连线

这也是阅读设备树时必须同时检查 machine wiring 的原因：DT 是 guest contract，不能
单独证明 host device graph 已经连接。

## 3. QEMU realize：从 CPU 对象到 host timer

### 3.1 三类状态对象

QEMU 没有建立一个独立的 `GenericTimerState` QOM device。timer 是 `ARMCPU` 的组成
部分，核心关系如下：

```text
MiniVirtMachineState
├── create_cpu ──> ARMCPU CPU0
│                  ├── CPUARMState env
│                  │   └── ARMGenericTimer c14_timer[7]
│                  ├── QEMUTimer gt_timer[7]
│                  └── qemu_irq gt_timer_outputs[7]
├── create_cpu ──> ARMCPU CPU1
│                  └── 同样拥有上述三组 per-CPU 状态
└── create_gic ──> GICv3State

ARMGenericTimer.cval/ctl
          │
          v
  gt_recalc_timer() <── host deadline 到期 ── QEMUTimer callback
          │
          v
  qemu_set_irq()
          │
          v
gt_timer_outputs[GTIMER_PHYS] ── mini-virt 连线 ──> GIC PPI 30

mini-virt 只把每个 ARMCPU 的 gt_timer_outputs[GTIMER_PHYS] 接到对应 CPU 的 GIC PPI 30
```

三类对象各自负责不同问题：

| 对象 | 关键字段 | 责任 |
| --- | --- | --- |
| `ARMGenericTimer` | `uint64_t cval`, `uint32_t ctl` | guest 可见的 architected timer state |
| `QEMUTimer` | `expire_time`, `timer_list`, `cb`, `opaque`, `scale` | host event loop 中的下一次 callback |
| `qemu_irq` | handler、opaque、GPIO number | 把 timer level 传播到 GIC input |

`CPUARMState.cp15.c14_timer[7]` 保存可迁移的 guest state；`ARMCPU.gt_timer[7]` 是运行
时调度工具；`ARMCPU.gt_timer_outputs[7]` 是 board wiring 的输出端。把这三者混成
“一个 timer 对象”会看不清 migration、deadline scheduling 和 interrupt routing 的
边界。

### 3.2 realize 时选择频率

`mini-virt` 没有给 CPU 的 `cntfrq` property 显式赋值。Cortex-A57 CPU type 带
`ARM_FEATURE_BACKCOMPAT_CNTFRQ`，所以 `arm_cpu_realizefn()` 选择：

```c
#define GTIMER_BACKCOMPAT_HZ 62500000

if (arm_feature(env, ARM_FEATURE_BACKCOMPAT_CNTFRQ) ||
    cpu->backcompat_cntfrq) {
    cpu->gt_cntfrq_hz = GTIMER_BACKCOMPAT_HZ;
}
```

随后：

```c
uint64_t scale = gt_cntfrq_period_ns(cpu); // 16 ns

cpu->gt_timer[GTIMER_PHYS] =
    timer_new(QEMU_CLOCK_VIRTUAL, scale, arm_gt_ptimer_cb, cpu);
```

七组 timer 使用相同 counter frequency 和不同 callback。`scale=16` 使
`timer_mod(timer, nexttick)` 能把 guest counter tick 直接换算为 host virtual-clock
纳秒 deadline。

### 3.3 realize 的 GDB backtrace

在 `qemu/target/arm/cpu.c:1709` 断住第一次 physical timer 创建，实测为：

```gdb
(gdb) break ../target/arm/cpu.c:1708
(gdb) run -machine mini-virt -smp 2 -m 4G -nographic \
  -kernel linux/build/arch/arm64/boot/Image \
  -dtb linux/build/arch/arm64/boot/dts/demo/mini-virt.dtb \
  -initrd busybox/build/initramfs.cpio.gz
```

```text
#0  arm_cpu_realizefn()                 target/arm/cpu.c:1709
#1  device_set_realized()               hw/core/qdev.c:523
#2  property_set_bool()                 qom/object.c:2376
#3  object_property_set()               qom/object.c:1450
#4  object_property_set_qobject()       qom/qom-qobject.c:28
#5  object_property_set_bool()          qom/object.c:1520
#6  qdev_realize()                      hw/core/qdev.c:276
#7  create_cpu()                        hw/arm/mini-virt.c:98
#8  mach_virt_init()                    hw/arm/mini-virt.c:192
#9  machine_run_board_init()            hw/core/machine.c:1744
#10 qemu_init_board()                   system/vl.c:2716
#11 qmp_x_exit_preconfig()              system/vl.c:2810
#12 qemu_init()                         system/vl.c:3850
#13 main()                              system/main.c:71

(gdb) p cpu->gt_cntfrq_hz
$1 = 62500000
(gdb) p scale
$2 = 16
```

这条栈说明 generic timer 的 host 调度对象是在 CPU realize 中创建，不是在
`create_gic()` 中创建。后者只负责把已经存在的 GPIO output 接到 GIC。

## 4. QEMU 如何仿真 system register

### 4.1 `ARMCPRegInfo` 把寄存器编码映射到 C callback

`generic_timer_cp_reginfo[]` 描述 AArch64 system register encoding、访问权限、保存
字段和读写函数。例如 `CNTP_CVAL_EL0` 对应：

```c
{
    .name = "CNTP_CVAL_EL0",
    .state = ARM_CP_STATE_AA64,
    .opc0 = 3, .opc1 = 3, .crn = 14, .crm = 2, .opc2 = 2,
    .access = PL0_RW,
    .type = ARM_CP_IO,
    .fieldoffset = offsetof(CPUARMState,
                            cp15.c14_timer[GTIMER_PHYS].cval),
    .accessfn = gt_ptimer_access,
    .readfn = gt_phys_redir_cval_read,
    .writefn = gt_phys_redir_cval_write,
}
```

TCG 翻译 guest `MSR CNTP_CVAL_EL0, xN` 时找到这份 metadata，运行时进入
`helper_set_cp_reg64()`。因为该寄存器标记为 `ARM_CP_IO`，helper 会持有 BQL 调用
`writefn`，避免 vCPU 写 timer state 时与 main-loop timer callback 并发修改。

运行时写入链为：

```text
guest MSR CNTP_CVAL_EL0
  -> helper_set_cp_reg64()
  -> gt_phys_redir_cval_write()
  -> gt_cval_write(GTIMER_PHYS)
  -> c14_timer[0].cval = value
  -> gt_recalc_timer()
```

`CNTP_CTL_EL0` 和 `CNTP_TVAL_EL0` 走相同框架，只是最终分别进入
`gt_ctl_write()` 和 `do_tval_write()`。

### 4.2 QEMU 不保存一个不断变化的 count 字段

TCG 模式下 `gt_get_countervalue()` 直接计算：

```c
return qemu_clock_get_ns(QEMU_CLOCK_VIRTUAL) /
       gt_cntfrq_period_ns(cpu);
```

普通非-icount 运行中，`QEMU_CLOCK_VIRTUAL` 基于 VM 已运行的 monotonic host time；
VM stop 时它停止。因此 QEMU 无需每 16 ns 修改一次 `CPUARMState`：读取 counter 时
现算，设置 deadline 时只注册一个 host timer。

这不是 cycle-accurate 仿真。QEMU 不知道一条 Cortex-A57 指令在真实流水线里消耗多少
cycle。若使用 `-icount`，`QEMU_CLOCK_VIRTUAL` 可由执行的 guest instruction count
推进，其目标是确定性和时间协调，也仍不是微架构 cycle model。参见
[QEMU TCG instruction counting](https://qemu.readthedocs.io/en/latest/devel/tcg-icount.html)。

### 4.3 `gt_recalc_timer()` 是核心状态机

所有会改变 timer condition 的路径最终调用 `gt_recalc_timer()`：

```text
if ENABLE == 0:
    ISTATUS = 0
    timer_del(host_timer)
    irq = 0

if ENABLE == 1:
    count = virtual_clock_ns / period_ns
    ISTATUS = (count - offset >= cval)

    if ISTATUS == 0:
        nexttick = cval + offset
    else:
        nexttick = counter wraparound point

    timer_mod(host_timer, nexttick)
    irq = ISTATUS && !IMASK
```

到期以后 `nexttick` 常显示为 `UINT64_MAX`。原因是 condition 已经成立，在软件设置
新的 compare value 前不会自动变回 0；下一次自然翻转要等 64-bit counter wrap。
这不是 QEMU 真准备等待到 `UINT64_MAX`，Linux 随即 mask 并写入下一次 CVAL。

`timer_mod()` 的单位由 `QEMUTimer.scale` 决定。本实验 `scale=16`，所以
`nexttick=0x547b532` 表示 counter deadline，timer queue 内的 ns deadline 是它乘以
16。`QEMUTimerList.active_timers` 按过期时间排序，main loop 只需等待队首。

### 4.4 host timer 到期 backtrace

在 `arm_gt_ptimer_cb()` 断住，实测 callback 由 QEMU main loop 执行：

```gdb
(gdb) break arm_gt_ptimer_cb
(gdb) run -machine mini-virt -smp 2 -m 4G -nographic \
  -kernel linux/build/arch/arm64/boot/Image \
  -dtb linux/build/arch/arm64/boot/dts/demo/mini-virt.dtb \
  -initrd busybox/build/initramfs.cpio.gz
```

```text
#0 arm_gt_ptimer_cb()                 target/arm/helper.c:1987
#1 timerlist_run_timers()             util/qemu-timer.c:563
#2 qemu_clock_run_timers()            util/qemu-timer.c:577
#3 qemu_clock_run_all_timers()        util/qemu-timer.c:664
#4 main_loop_wait()                   util/main-loop.c:603
#5 qemu_main_loop()                   system/runstate.c:903
#6 qemu_default_main()                system/main.c:50
#7 main()                             system/main.c:93

(gdb) p ((ARMCPU *)opaque)->env.cp15.c14_timer[0]
$1 = { cval = 131668575, ctl = 1 }
```

callback 自身只做一件事：

```c
void arm_gt_ptimer_cb(void *opaque)
{
    ARMCPU *cpu = opaque;
    gt_recalc_timer(cpu, GTIMER_PHYS);
}
```

它再次读取当前 count，形成 `ISTATUS`，并更新 IRQ。真正的架构语义集中在
`gt_recalc_timer()`，host timer framework 只负责在 deadline 附近把控制权交回来。

### 4.5 从 timer output 到 GIC PPI

`gt_update_irq()` 从 `ctl` 计算电平：

```c
int irqstate = (gt->ctl & 6) == 4; // ISTATUS=1, IMASK=0
qemu_set_irq(cpu->gt_timer_outputs[timeridx], irqstate);
```

CPU0 physical timer 拉高时，在 `gicv3_set_irq()` 断住得到：

```gdb
(gdb) break gicv3_set_irq if irq == 286 && level == 1
```

```text
#0  gicv3_set_irq(irq=286, level=1)   hw/intc/arm_gicv3.c:381
#1  qemu_set_irq(level=1)             hw/core/irq.c:34
#2  gt_update_irq(timeridx=0)         target/arm/helper.c:1373
#3  gt_recalc_timer(timeridx=0)       target/arm/helper.c:1534
#4  gt_ctl_write(value=1)             target/arm/helper.c:1609
#5  gt_phys_redir_ctl_write()         target/arm/helper.c:1711
#6  helper_set_cp_reg64()             target/arm/tcg/op_helper.c:1006
#7  code_gen_buffer()
#8  cpu_tb_exec()                     accel/tcg/cpu-exec.c:439
#9  cpu_loop_exec_tb()                accel/tcg/cpu-exec.c:891
#10 cpu_exec_loop()                   accel/tcg/cpu-exec.c:1001
#11 cpu_exec_setjmp()                 accel/tcg/cpu-exec.c:1018
#12 cpu_exec()                        accel/tcg/cpu-exec.c:1044
#13 tcg_cpu_exec()                    accel/tcg/tcg-accel-ops.c:82
#14 mttcg_cpu_thread_fn()             accel/tcg/tcg-accel-ops-mttcg.c:93
```

这一样本发生在 guest 写 `CTL.ENABLE=1` 时：写入当刻 condition 已满足，于是 vCPU
线程直接拉高 IRQ。正常未来 deadline 的拉高则由上一节 main-loop callback 触发。
两条路径都会收敛到 `gt_recalc_timer() -> gt_update_irq() -> qemu_set_irq()`。

进入 GIC 后，PPI 路径为：

```text
gicv3_set_irq(input 286)
  -> input >= 256，属于 per-CPU input
  -> cpu = (286 - 256) / 32 = 0
  -> intid = (286 - 256) % 32 = 30
  -> gicv3_redist_set_irq(CPU0, 30, level)
  -> gicv3_cpuif_update()
  -> arm_cpu_set_irq(ARM_CPU_IRQ)
  -> cpu_interrupt(CPU_INTERRUPT_HARD)
  -> TCG 在可中断边界退出 TB
  -> arm_cpu_exec_interrupt()
  -> arm_cpu_do_interrupt()
```

PPI 的 pending/active/enable/priority 状态属于对应 `GICv3CPUState`，所以 CPU0 和 CPU1
使用相同 INTID 30 也不会互相覆盖。

## 5. QEMU trace：观察一次完整 timer 周期

### 5.1 启用 trace

QEMU 已提供以下 ARM timer tracepoint：

```text
arm_gt_cval_write
arm_gt_tval_write
arm_gt_ctl_write
arm_gt_imask_toggle
arm_gt_recalc
arm_gt_recalc_disabled
arm_gt_update_irq
arm_gt_cntvoff_write
arm_gt_cntpoff_write
```

在仓库根目录可直接运行：

```sh
qemu/build/qemu-system-aarch64 \
  -trace 'enable=arm_gt_*' \
  -trace 'file=/tmp/syslab-timer-trace.log' \
  -machine mini-virt -smp 2 -m 4G -nographic \
  -kernel linux/build/arch/arm64/boot/Image \
  -dtb linux/build/arch/arm64/boot/dts/demo/mini-virt.dtb \
  -initrd busybox/build/initramfs.cpio.gz \
  -append 'console=ttyAMA0 earlycon=pl011,0x09000000 rdinit=/init panic=-1'
```

全量 `arm_gt_*` 在 periodic tick 下输出很多；定位一个周期时可以过滤 `timer 0`，或
只启用 `cval_write`、`ctl_write`、`recalc` 和 `update_irq`。

### 5.2 实测 trace 解读

2026-09-14 的一次完整启动中，trace 片段为：

```text
arm_gt_cval_write gt_cval_write: timer 0 value 0x63bb3c1
arm_gt_recalc_disabled gt recalc: timer 0 timer disabled
arm_gt_update_irq gt_update_irq: timer 0 irqstate 0
arm_gt_ctl_write gt_ctl_write: timer 0 value 0x1
arm_gt_recalc gt recalc: timer 0 next tick 0x63bb3c1
arm_gt_update_irq gt_update_irq: timer 0 irqstate 0

arm_gt_recalc gt recalc: timer 0 next tick 0xffffffffffffffff
arm_gt_update_irq gt_update_irq: timer 0 irqstate 1

arm_gt_ctl_write gt_ctl_write: timer 0 value 0x7
arm_gt_imask_toggle gt_ctl_write: timer 0 IMASK toggle
arm_gt_update_irq gt_update_irq: timer 0 irqstate 0

arm_gt_cval_write gt_cval_write: timer 0 value 0x6447d90
arm_gt_recalc gt recalc: timer 0 next tick 0x6447d90
arm_gt_update_irq gt_update_irq: timer 0 irqstate 0
arm_gt_ctl_write gt_ctl_write: timer 0 value 0x5
arm_gt_imask_toggle gt_ctl_write: timer 0 IMASK toggle
arm_gt_update_irq gt_update_irq: timer 0 irqstate 0
```

逐段对应：

1. Linux 写入第一次绝对 deadline，但 timer 尚未 enable，所以 QEMU 只保存 CVAL。
2. `CTL=1` 表示 `ENABLE=1, IMASK=0, ISTATUS=0`，host timer 被排到
   `0x63bb3c1` tick。
3. deadline 到达，QEMU 重新计算出 condition 成立，内部 CTL 变为 `0x5`，IRQ 拉高。
4. Linux IRQ handler 读到 `ISTATUS` 后写 `CTL=0x7`，即保留 enable 和 status、设置
   mask，IRQ 立即拉低。
5. generic tick 层安排下一事件，写新 CVAL。此时新 deadline 在未来，QEMU 清除
   `ISTATUS`，内部 CTL 回到 `0x3`。
6. Linux 写 `CTL=0x5` 清 IMASK；QEMU 接收的可写低两位实际为 `ENABLE=1,
   IMASK=0`，重新开放下一次中断。

这里 trace 打印的 `value=0x5/0x7` 包含 Linux 从 CTL 读回的 `ISTATUS` 位；
`gt_ctl_write()` 只把低两位写回保存状态，bit 2 仍由 QEMU 根据 condition 计算。

本次约 6 秒的 guest 运行共产生：

```text
trace lines : 23478
IRQ high    : 2134
CVAL writes : 2134
```

数量与 `HZ=250`、2 个 CPU、启动阶段和运行时间相符，但它不是严格性能测量。trace
本身、启动负载和取样边界都会改变运行时序。

## 6. Linux：从 DT probe 到 periodic tick

### 6.1 DT probe 与 PPI 选择

`TIMER_OF_DECLARE(..., "arm,armv8-timer", arch_timer_of_init)` 使 early timer probe
匹配 mini-virt 的 `/timer` node。`arch_timer_of_init()` 完成四件核心工作：

```text
of_irq_get() 解析四个 PPI
  -> arch_timer_ppi[]

MRS CNTFRQ_EL0
  -> arch_timer_rate = 62,500,000

arch_timer_select_ppi()
  -> ARCH_TIMER_PHYS_NONSECURE_PPI

arch_timer_register() + arch_counter_register()
  -> per-CPU clockevent + global clocksource
```

驱动中的关键全局和 per-CPU 数据是：

```c
static u32 arch_timer_rate;
static int arch_timer_ppi[ARCH_TIMER_MAX_TIMER_PPI];
static enum arch_timer_ppi_nr arch_timer_uses_ppi;
static struct clock_event_device __percpu *arch_timer_evt;
static struct clocksource clocksource_counter;
```

`arch_timer_rate` 与 PPI 映射是整个平台共享的描述；`arch_timer_evt` 必须 per-CPU，
因为硬件 timer 和 PPI 都属于各自 PE。

### 6.2 同一硬件提供 clocksource 与 clockevent

两个 kernel abstraction 用途不同：

| abstraction | 回答的问题 | mini-virt 使用的寄存器 | Linux 对象 |
| --- | --- | --- | --- |
| clocksource | “现在经过了多少时间？” | `CNTPCT_EL0` | `clocksource_counter` |
| clockevent | “请在 N tick 后通知当前 CPU” | `CNTP_CVAL_EL0`, `CNTP_CTL_EL0`, PPI 30 | per-CPU `arch_timer_evt` |

clocksource 是只读、连续的时间基准；clockevent 是可编程的一次性 deadline。即使
kernel 配置为 periodic tick，driver 仍把 Generic Timer 注册成
`CLOCK_EVT_FEAT_ONESHOT`，generic tick 层在每次中断后设置下一次 CVAL，软件形成
250 Hz 周期。

当前配置没有 high-resolution timer，也没有 NO_HZ：

```text
CONFIG_HZ_PERIODIC=y
CONFIG_HZ_250=y
CONFIG_HZ=250
CONFIG_HIGH_RES_TIMERS is not set
CONFIG_NO_HZ is not set
```

所以每 CPU 的目标 tick period 是 4 ms：

```text
62,500,000 tick/s / 250 event/s = 250,000 counter ticks/event
250,000 * 16 ns = 4,000,000 ns
```

guest `/proc/timer_list` 也报告 `resolution: 4000000 nsecs`。

### 6.3 设置下一事件

generic clockevent 层把纳秒 deadline 换算成 device tick 数，调用 driver 的
`set_next_event`。physical timer 路径最终执行：

```c
ctrl = read_sysreg(cntp_ctl_el0);
ctrl |= ARCH_TIMER_CTRL_ENABLE;
ctrl &= ~ARCH_TIMER_CTRL_IT_MASK;

cnt = __arch_counter_get_cntpct();
write_sysreg(evt + cnt, cntp_cval_el0);
write_sysreg(ctrl, cntp_ctl_el0);
isb();
```

先写未来 CVAL，再 enable/unmask。`CVAL` 是 absolute counter value，所以即使
interrupt delivery 有延迟，deadline 的含义也不会漂移成“从 handler 返回后再等
4 ms”。

### 6.4 IRQ handler

IRQ 到达后的 Linux 核心路径是：

```text
AArch64 vector
  -> el1h_64_irq_handler()
  -> el1_interrupt()
  -> do_interrupt_handler(handle_arch_irq)
  -> gic_handle_irq()
  -> gic_read_iar() 得到 INTID 30
  -> generic_handle_domain_irq()
  -> arch_timer_handler_phys()
  -> timer_handler(ARCH_TIMER_PHYS_ACCESS)
```

driver handler 的核心逻辑很短：

```c
ctrl = read_sysreg(cntp_ctl_el0);
if (ctrl & ARCH_TIMER_CTRL_IT_STAT) {
    ctrl |= ARCH_TIMER_CTRL_IT_MASK;
    write_sysreg(ctrl, cntp_ctl_el0);
    evt->event_handler(evt);
    return IRQ_HANDLED;
}
return IRQ_NONE;
```

`evt->event_handler` 在本配置下是 `tick_handle_periodic()`。它更新 jiffies、timekeeping
和 process accounting，然后按下一个 4 ms 边界调用 `clockevents_program_event()`，
后者再进入 `arch_timer_set_next_event_phys()` 写 CVAL 和清 IMASK。

把 Linux 和 QEMU 的状态动作对齐如下：

| Linux 动作 | guest register | QEMU 动作 |
| --- | --- | --- |
| 读当前时间 | `MRS CNTPCT_EL0` | 按 virtual clock 即时计算 count |
| 设置下一事件 | `MSR CNTP_CVAL_EL0` | 保存 cval，重排 `QEMUTimer` |
| enable/unmask | `MSR CNTP_CTL_EL0` | 更新 ctl，重新计算 condition 和 IRQ |
| deadline 到达 | 无 guest 指令 | host callback 设置 ISTATUS 并拉高 PPI |
| handler mask | `MSR CNTP_CTL_EL0` | IRQ 拉低 |
| GIC EOI/deactivate | `ICC_EOIR1_EL1` 等 | 清 GIC active state；不改变 timer condition |

### 6.5 为什么 clocksource 最终读 physical count

`arch_counter_register()` 在 EL2 可用且选择 physical PPI 时，把
`arch_timer_read_counter` 指向 `arch_counter_get_cntpct()`。arm64 accessor 执行：

```asm
isb
mrs xN, cntpct_el0
```

`ISB` 和随后 `arch_counter_enforce_ordering()` 处理 speculative counter read 与内存
访问的顺序。counter 是硬件时间源，但 `MRS` 仍可能被 CPU pipeline 推测执行；读取
时间用于给事件排序时，必须遵守架构规定的 ordering sequence。支持 FEAT_ECV 的新 CPU
还可用 self-synchronized `CNTPCTSS_EL0/CNTVCTSS_EL0`，当前 Cortex-A57 不走该路径。

## 7. 运行时证据

### 7.1 启动日志

使用 mini-virt 的既有 Image、DTB 和 initramfs 启动，关键日志为：

```text
[    0.000000] GICv3: GICv3 features: 16 PPIs
[    0.000000] GICv3: CPU0: found redistributor 0 region 0:0x080a0000
[    0.000000] arch_timer: cp15 timer(s) running at 62.50MHz (phys).
[    0.000000] clocksource: arch_sys_counter: mask: 0x1ffffffffffffff ...
[    0.000171] sched_clock: 57 bits at 63MHz, resolution 16ns ...
[    0.112943] GICv3: CPU1: found redistributor 1 region 0:0x080c0000
[    0.434884] clocksource: Switched to clocksource arch_sys_counter
```

这些信息分别证明：GIC 提供 PPI、driver 选择 CP15/system-register physical timer、
频率为 62.5 MHz、counter 被注册为 clocksource、CPU1 的 redistributor 也已初始化。

### 7.2 guest sysfs 与 `/proc/interrupts`

实测：

```text
# cat /sys/devices/system/clocksource/clocksource0/current_clocksource
arch_sys_counter

# cat /sys/devices/system/clocksource/clocksource0/available_clocksource
arch_sys_counter jiffies

# cat /proc/interrupts
           CPU0       CPU1
 10:        591        563     GICv3  30 Level     arch_timer
 13:          1          0     GICv3  33 Level     uart-pl011
IPI4:         0          0       Timer broadcast interrupts
```

两列非零说明每个 CPU 的 PPI 30 都实际到达 Linux。`Level` 与 DT flags 和 Generic
Timer 输出语义一致。`Timer broadcast interrupts` 为 0 也符合当前无 deep idle、无
NO_HZ 的简单 VM 环境；每 CPU local timer 足以工作。

### 7.3 证据能证明什么

当前 evidence chain 是：

```text
ARM register semantics
  + mini-virt source wiring
  + CPU realize GDB
  + system-register/IRQ GDB
  + QEMU trace state transitions
  + guest driver banner/sysfs/interrupt counts
```

它证明当前 TCG、2 vCPU、physical timer、PPI 30、periodic tick 路径闭环。它没有验证：

- KVM accelerator 下 kernel irqchip 和 in-kernel timer 的路径
- `-icount` 下由 instruction count 推进 virtual clock 的行为
- virtual、secure、EL2 timer PPI，因为 mini-virt 尚未连接这些 GPIO output
- CPU suspend、counter stop、timer broadcast、NO_HZ 或 high-resolution timer
- migration 前后 timer state 和 pending IRQ 的保持

## 8. 源码阅读路线

按数据流阅读比按目录阅读更容易建立整体模型：

1. 从 `linux/arch/arm64/boot/dts/demo/mini-virt.dts` 确认四个 PPI 和触发类型。
2. 看 `qemu/hw/arm/mini-virt.c:create_gic()`，确认当前只连接 physical output。
3. 看 `qemu/target/arm/cpu.h` 中 `ARMGenericTimer`、`gt_timer[]`、
   `gt_timer_outputs[]` 的所有权。
4. 看 `qemu/target/arm/cpu.c:arm_cpu_realizefn()`，确认频率、scale、clock type 和
   callback。
5. 看 `qemu/target/arm/helper.c:generic_timer_cp_reginfo[]`，把 system register encoding
   对到 access/read/write callback。
6. 重点读 `gt_get_countervalue()`、`gt_recalc_timer()`、`gt_update_irq()`，理解按需
   counter、deadline queue 和 level IRQ。
7. 看 `qemu/hw/intc/arm_gicv3.c:gicv3_set_irq()`，理解 GPIO input 286 如何变成
   CPU0 PPI INTID 30。
8. 最后看 `linux/drivers/clocksource/arm_arch_timer.c` 的 probe、clocksource、
   clockevent、handler 四段，闭合 guest software 路径。

最值得反复确认的分界是：system counter 给出“现在”，per-CPU timer 保存“何时通知”，
QEMU host timer 负责“何时回来重新计算”，GIC 负责“把已经形成的电平送到哪个 CPU”，
Linux clockevent 负责“下一次希望何时收到通知”。
