# QEMU icount：指令数作为时钟源

本文以本仓库 QEMU `a5ed11b21a`、mini-virt `-smp 2`、AArch64 TCG 为边界。它解释的是
**guest 指令计数驱动的虚拟时间**。文中的 `syscnt` 指 ARM architectural system counter；
Linux 读取物理 counter `CNTPCT_EL0`，用它作 `arch_sys_counter` clocksource.

## 先建立一张心智图

```text
guest 执行一条 AArch64 指令
  → TCG 翻译块 TB 的指令预算减少 1
  → 全局 qemu_icount 累加已执行 guest 指令数
  → QEMU_CLOCK_VIRTUAL = bias + (qemu_icount << shift) ns
  → CNTPCT_EL0 = floor(QEMU_CLOCK_VIRTUAL / 16 ns)
  → CNTP_CVAL_EL0 与当前 counter 比较；到期执行 QEMUTimer callback
  → GTIMER_PHYS GPIO → GIC PPI 30 → ARM CPU IRQ → Linux arch timer handler
```

这里有三个不同单位：`qemu_icount` 是 guest 指令**条数**；`QEMU_CLOCK_VIRTUAL` 是
QEMU 内部的 **虚拟 ns** ；`CNTPCT_EL0` 是 62.5 MHz counter 的 **tick** 。例如
`-icount shift=3` 令一条 guest 指令推进 `2^3 = 8` 虚拟 ns；mini-virt 的 counter
period 为 16 ns，所以连续执行且不发生 clock warp 时，约两条 guest 指令推进一个
counter tick。精确表达式是 `floor((bias + N * 8) / 16)`，不是在 guest 中保存一个
每执行两条指令就递增的硬件寄存器。`bias` 还用于空闲 warp、迁移等时间调整。

## 为什么选 `2^shift` ns/指令

首先要选的是一种**逻辑时间尺度**：原始 `qemu_icount` 只有 guest 指令条数，
`QEMU_CLOCK_VIRTUAL` 和 QEMU timer API 却使用 ns。QEMU 的约定是每执行一条
guest 指令，虚拟时钟增加 `2^shift` ns。`shift=3` 对应 8 ns/指令，即
125 MIPS 的逻辑速率；它没有声称真实 A57 每条指令耗时 8 ns。源码把
`shift` 限在 0–10，给最大值的注释是“任意选约 1 MIPS 为最低速率”；
这也表明它是模拟策略参数，不是从目标 CPU 频率算出的物理常数。
[QEMU 命令行文档](https://www.qemu.org/docs/master/system/invocation.html#cmdoption-icount)
明确给出这个约定及 `shift=auto` 的调速用途；
[TCG icount 开发文档](https://www.qemu.org/docs/master/devel/tcg-icount.html)
说明它服务于虚拟时间、deadline 和确定性，不模拟真实 CPU 周期。

采用 2 的幂使 **指令数到 ns** 和 **剩余 ns 到指令预算** 成为一对纯整数换算。
这份 checkout 的源码直接展示了两边：

```text
正向：已执行 N 条指令
  icount_to_ns(N) = N << shift                 accel/tcg/icount-common.c
  virtual_ns = qemu_icount_bias + icount_to_ns(N)

反向：下一个 timer 距今 D ns
  icount_round(D) = (D + 2^shift - 1) >> shift  同上
                  = ceil(D / 2^shift)
  将结果作为 guest 指令预算                 accel/tcg/tcg-accel-ops-icount.c
```

反向必须**向上取整**：例如 `shift=3`、deadline 还差 17 ns，执行 2 条只推进
16 ns，timer 尚未到期；预算为 3 条才会跨过 deadline。`translator.c` 的 TB
入口扣预算，`cpu-exec.c` 必要时重译短 TB，让执行在相应的**guest 指令边界**
退出并处理 timer。单看这次向上取整造成的误差，跨越 deadline 时最多晚于
它不足一个指令量子的虚拟 ns；其它事件和调度仍可能影响实际回调时机，
这不等于真实硬件周期精度。mini-virt 恰有 16 ns/counter tick，`shift=3`
给出两条指令一 tick 的直观例子，但 `shift` 并非由 62.5 MHz 的 CNTFRQ
自动推导，换个值也能运行。

`shift=auto` 则把这个尺度当作可调的档位：虚拟时间超前 host 时，减小
`shift`，让后续指令推进更少的虚拟 ns；落后时增大 `shift`。这里真正巧妙的
是改档时重新计算 `qemu_icount_bias`，令**当前虚拟时间不跳变**：

```text
调整前：T = old_bias + N * 2^old_shift
调整后：new_bias = T - N * 2^new_shift
        new_bias + N * 2^new_shift = T
```

对应 `accel/tcg/icount-common.c:icount_adjust()`：它先读 `cur_icount`
（当前虚拟 ns），再修改 shift，最后设置
`qemu_icount_bias = cur_icount - (qemu_icount << new_shift)`。后续指令的
虚拟时间斜率变了，但此刻的 counter 不会仅因调档而突变。固定 `shift` 不做
这种 host 对齐调节；`bias` 仍可能因空闲 clock warp 改变。

## 不开 icount：虚拟时钟来自 host 单调时间

不开 icount 时，通常的 TCG 路径没有安装加速器的 `get_virtual_clock` 回调，
取时钟的路径如下：

```text
qemu_clock_get_ns(QEMU_CLOCK_VIRTUAL)         util/qemu-timer.c
  cpus_get_virtual_clock()                    system/cpus.c
    没有加速器 get_virtual_clock 回调
    cpu_get_clock()                           system/cpu-timers.c
      cpu_get_clock_locked()
        cpu_clock_offset + get_clock()
          get_clock()                         include/qemu/timer.h
            clock_gettime(CLOCK_MONOTONIC)   Linux host 的正常分支
```

`cpu_clock_offset` 让 VM 停止时虚拟时钟暂停，因此结果是 VM 运行期间经过的
单调时间，并非裸的 host 开机时间。

ARM counter 的读取函数是 `target/arm/helper.c` 中的 `gt_get_countervalue()`：

```c
return qemu_clock_get_ns(QEMU_CLOCK_VIRTUAL) / gt_cntfrq_period_ns(cpu);
```

`gt_cntfrq_period_ns()` 在 `target/arm/cpu.c` 使用整数 ns/tick。mini-virt 的默认
Cortex-A57 使用 `GTIMER_BACKCOMPAT_HZ = 62500000`，于是 `1e9 / 62500000 = 16`
ns/tick。`CNTPCT_EL0` 读还可能减去体系结构规定的 offset；本 VM 的普通 Linux
物理 timer 路径可按上式理解。定时器比较值写入 `CNTP_CVAL_EL0`，或通过
`CNTP_TVAL_EL0` 写入相对时间后转成 CVAL，最终进入 `gt_recalc_timer()`：

```c
count = gt_get_countervalue(&cpu->env);
istatus = count - offset >= gt->cval;
timer_mod(cpu->gt_timer[timeridx], nexttick);
gt_update_irq(cpu, timeridx);
```

`timer_new(QEMU_CLOCK_VIRTUAL, scale, arm_gt_ptimer_cb, cpu)` 的 `scale` 也为
16 ns/tick，`nexttick` 以 counter tick 表示。不开 icount 时，到期路径是：

```text
main_loop_wait()                              util/main-loop.c
  qemu_clock_run_all_timers()                 util/qemu-timer.c
    qemu_clock_run_timers(QEMU_CLOCK_VIRTUAL)
      timerlist_run_timers()
        arm_gt_ptimer_cb()                    target/arm/helper.c
          gt_recalc_timer()
            gt_update_irq()
              qemu_set_irq(gt_timer_outputs[GTIMER_PHYS], level)
                GIC PPI 30 → CPU IRQ            hw/arm/mini-virt.c:create_gic()
```

mini-virt 将每个 CPU 的物理 timer GPIO 接到对应的 GIC PPI 30. 这里的 host
定时器主要负责**唤醒 QEMU 并检查到期**；guest 可见 counter 值仍按
`QEMU_CLOCK_VIRTUAL` 计算。

## 开 icount：换掉时钟来源，保留 ARM timer 路径

`-icount shift=N` 让相同的 ARM counter 读函数换用 icount 时钟源：

```text
-icount shift=N
  icount_configure()                          accel/tcg/icount-common.c
    use_icount = ICOUNT_PRECISE
  tcg_accel_ops_init()                        accel/tcg/tcg-accel-ops.c
    get_virtual_clock = icount_get
  qemu_clock_get_ns(QEMU_CLOCK_VIRTUAL)
    cpus_get_virtual_clock()
      icount_get()                            accel/tcg/icount-common.c
```

`gt_get_countervalue()` 不需要针对 icount 另写实现，取到的虚拟 ns 变成：

```c
/* accel/tcg/icount-common.c，略去 seqlock */
icount_get() = qemu_icount_bias + icount_to_ns(qemu_icount);
icount_to_ns(n) = n << icount_time_shift;
```

运行中的 guest 指令数可能还在当前 vCPU 的预算差值里。取时间时还会做一次
结账：

```text
icount_get()
  icount_get_locked()
    icount_get_raw_locked()
      当前 vCPU 正在运行？
        can_do_io=false → 报错 Bad icount read
        否则 → icount_update_locked(current_cpu)  先结账
      读取全局 qemu_icount
    qemu_icount 按 shift 换算成 ns，再加上 qemu_icount_bias
```

这样设备/系统寄存器在指令中读虚拟时钟时，可以看见截至当前指令的时间，无须
等待整批 TB 结束。`qemu_icount_bias` 不代表额外执行的指令；它是将空闲时间等
映射进虚拟时钟的偏移量。

所以 **host 单调时钟没有从整个 QEMU 消失**：`QEMU_CLOCK_VIRTUAL_RT` 仍可通过
`cpu_get_clock()` 参考 host 时间；`shift=auto`、`sleep=on` 的空闲推进和
`align=on` 也可能使用它。但在固定 `shift`、运行 guest 指令的路径中，
`CNTPCT_EL0` 不再按每次读取时的 host `clock_gettime()` 直接换算。

## TB 怎么数 guest 指令：并不靠 PC 自增

TCG 的 TB（translation block）是一段按 guest ISA 解码、翻译后可复用的 host
代码；一条 guest 指令可变成多条 TCG/host 指令，也可能调用 C helper。因此不能
数 host 指令，更不能拿 `PC_new - PC_old` 除以 4：分支会跳转，AArch32 Thumb
指令宽度不固定，异常也会改变 PC。

计数依据是翻译时解码出的 guest 指令条数：

```text
translator_loop()                             accel/tcg/translator.c
  每解码并翻译一条 guest 指令
    ++db->num_insns
  gen_tb_end()
    将 num_insns 填入 TB 开头预留的减法
  tb->icount = db->num_insns
```

`gen_tb_start()` 在 TB 开头预留减法，`gen_tb_end()` 才知道该 TB 实际有几条
指令。生成的代码在运行时大致执行：

```c
/* 概念对应真实 TCG 生成顺序，字段名与源码一致 */
count = cpu->neg.icount_decr.u32;
count -= tb->icount;
if ((int32_t)count < 0) exit_tb(TB_EXIT_REQUESTED);
cpu->neg.icount_decr.u16.low = count;
/* 随后执行 TB 翻译出的 guest 语义 */
```

预算具体落在每个 `CPUState` 的字段中（定义见 `include/hw/core/cpu.h`）：

- `icount_budget`：本轮尚未结算的指令额度，类型为 `int64_t`。在
  `icount_prepare_for_run()` 中装入；`icount_update()` 结算一部分已执行指令
  时，它也相应减小。
- `neg.icount_decr.u16.low`：生成的 TB 在入口直接递减的低 16 位额度，
  一次最多装 `0xffff` 条指令。
- `icount_extra`：本轮额度超过低 16 位时，暂存未装入 `u16.low` 的余额。
- `neg.icount_decr.u16.high`：可由 `cpu_exit()`/interrupt 置成 `-1`，
  让 TB 入口的 32 位合并检查退出；它不是另一份指令预算。

例如装入 10 条时，`icount_budget=10`、`u16.low=10`、`icount_extra=0`。
进入一个 3 条指令的 TB 后，低位变成 7；结算时算出 `10-(7+0)=3`
条已执行指令，随后 `icount_budget` 变为 7，全局 `qemu_icount` 增加 3。
每执行一个 TB，在 TB **入口**预扣整块的条数；这只是
高效的账务办法，不表示 TB 内部每条指令都已执行。若发生异常、MMIO、helper
退出，`cpu_restore_state_from_tb()` 会把未执行的 `insns_left` 加回预算，并恢复
精确 guest 状态。当前 TB 比剩余预算长时，CPU 执行循环会用 `cflags_next_tb`
重新生成恰好可运行的短 TB：

```text
TB 内部提前退出
  cpu_restore_state_from_tb()                 accel/tcg/translate-all.c
    恢复 guest 指令位置
    icount_decr.u16.low += insns_left

剩余预算 < 下一个 TB 的 tb->icount
  cpu_exec_loop()                            accel/tcg/cpu-exec.c
    cflags_next_tb = 剩余预算
    重译较短 TB，再执行到预算边界
```

全局计数的关系更清楚：

```c
executed = cpu->icount_budget
         - (cpu->neg.icount_decr.u16.low + cpu->icount_extra);
cpu->icount_budget -= executed;
timers_state.qemu_icount += executed;
```

这是 `icount_get_executed()` 和 `icount_update_locked()` 的核心，位于
`accel/tcg/icount-common.c`。本轮额度通常从最近的虚拟 timer deadline 来，
还会受其它 timer 与 vCPU 轮转限制：

```text
icount_prepare_for_run()                      accel/tcg/tcg-accel-ops-icount.c
  icount_get_limit()
    qemu_clock_deadline_ns_all(QEMU_CLOCK_VIRTUAL)  最近到期时间，单位 ns
    同时检查 QEMU_CLOCK_REALTIME 的最近 deadline
    icount_round(deadline)                         向上取整，单位 guest 指令
  设置 icount_budget、icount_decr.u16.low、icount_extra

tcg_cpu_exec()                                执行可用预算内的 guest 指令
icount_process_data()                         结账，更新全局 qemu_icount
```

虚拟 timer 仍按时间排队，CPU 则只运行到足够让它到期的 guest 指令边界。

为什么需要给 MMIO 和 timer 寄存器额外处理？原因是 **TB 在入口一次预扣整块
的指令数**。假设一个 TB 有四条 guest 指令：

```text
第 1 条 ADD
第 2 条 ADD
第 3 条 LDR [设备寄存器]    ← MMIO
第 4 条 ADD

TB 入口预扣 4 条。执行到第 3 条、准备访问设备时，第 4 条还没有执行；
若直接用预扣后的计数读取 QEMU_CLOCK_VIRTUAL，设备会看见“已执行 4 条”的时间。
正确的访问时刻应当对应第 3 条，而不能把第 4 条提前算进去。
```

普通 RAM load/store 没有在指令中调用设备模型，通常可以留在多指令 TB 中。
但 load/store 的目标地址可能要到运行时才知道是否是 MMIO。QEMU 的处理是：

```text
translator_loop()                             accel/tcg/translator.c
  多指令 TB：在前面指令处设 can_do_io=false；最后一条前设为 true

第 3 条 LDR 实际命中 MMIO
  io_prepare()                                accel/tcg/cputlb.c
    can_do_io=false → cpu_io_recompile()      accel/tcg/translate-all.c
      cpu_restore_state_from_tb()
        恢复到第 3 条的 PC；退还第 3、4 条共 2 条的预扣计数
      重新翻译只含第 3 条 LDR 的 TB，再执行该指令的 MMIO 访问
```

在新 TB 中第 3 条是最后一条，执行设备访问时计数只包含第 1–3 条。这里的
“重编译”只针对**运行时发现落到 MMIO、而且它原来不在 TB 末尾**的情形；
普通 RAM 访问不会因此变成一条指令一个 TB。

ARM timer 系统寄存器是另一种情况：翻译时就知道 `CNTPCT_EL0` 读取当前
虚拟时间、`CNTP_CVAL_EL0` 写入会重排 timer。它们在 `target/arm/helper.c`
的寄存器定义带 `ARM_CP_IO` 标记；AArch64 翻译器看到这个标记就调用
`translator_io_start()`，让该指令成为 TB 的最后一条：

```text
ARM_CP_IO 标记                              target/arm/helper.c
  系统寄存器翻译                            target/arm/tcg/translate-a64.c
    translator_io_start()                    accel/tcg/translator.c
      该指令之后结束 TB
      访问 counter/CVAL 时，TB 内没有后续指令被预扣
```

因此，读 counter 时可以把截至这条指令的已执行数结算到全局 icount；写 CVAL
安排的下一次 timer deadline 也对应正确的 guest 指令位置。这里追求的是
**事件发生在哪条 guest 指令上**，并没有给 MMIO 或系统指令增加真实硬件耗时。

## 为什么 mini-virt 的两个核要用一个 TCG 线程

这里的“single thread”指 **两个 guest vCPU 共用一个执行 TCG 代码的 host
线程**，并非 guest 只能有一个 CPU，也非整个 QEMU 只有一个线程：

```text
rr_start_vcpu_thread()                        accel/tcg/tcg-accel-ops-rr.c
  CPU0 → 创建 host 线程「ALL CPUs/TCG」
  CPU1 → 共用同一线程、halt_cond

rr_cpu_thread_fn()                            同上
  icount_percpu_budget(cpu_count)             为本轮各 vCPU 分配预算
  CPU0: icount_prepare_for_run()
        tcg_cpu_exec()
        icount_process_data()
  CPU1: icount_prepare_for_run()
        tcg_cpu_exec()
        icount_process_data()
  下一轮继续
```

这使 guest 指令、由它们触发的 MMIO 与 timer 检查进入一个可排序的流，
`timers_state.qemu_icount` 才能代表**全机**的单调指令进度。上图是双核
mini-virt 的轮转示意；实际循环会跳过停止或 halted 的 vCPU。

假如两个 host 线程同时执行两个 vCPU，即使原子地相加各自指令数，仍无法只凭
总数确定“CPU0 第 100 条指令写设备”和“CPU1 第 80 条指令读设备”谁先发生，
timer 到期究竟插在哪个访问之前也会受 host 调度影响。更麻烦的是当前实现的
TB 入口预扣、处理中途 I/O 时的纠偏、全局 `qemu_icount` 更新和按 deadline
分配预算，都依赖 vCPU 执行点能被顺序化。原子计数只解决丢更新，不能解决
**事件的全序**。所以这份 QEMU 实现明确拒绝 `-icount` + `thread=multi`：

```text
tcg_set_thread()                             accel/tcg/tcg-all.c
  thread=multi 且 icount 已启用
    报错：No MTTCG when icount is enabled

tcg_init_machine()                           同上
  未显式指定线程模式，且 icount 已启用
    自动选择 single
```

理论上可设计带确定性同步/仲裁的并行模拟器，
因此“单线程”不是指令计数的数学定理，而是这套 icount 时序语义和实现的必要
条件。

单线程的代价很直接：多个 guest 核不能在 host 多核上并行跑 TCG；再加 TB
预算检查、deadline、I/O 切块、计数结账、可能的 record/replay 记录，通常比
普通 MTTCG 慢。速度差别还取决于 guest、host、I/O 和 `shift/sleep`，这里不
给没有同条件实测的倍数。

## ADD、DIV、load/store 与真实“耗时”怎么处理

icount **有意不区分** ADD、MUL、DIV、分支、RAM load/store 或大多数系统指令
在真实 Cortex-A57 上的周期数。对完成的一条 guest 指令，预算通常减少 1；
`shift=N` 赋予它相同的 `2^N` 虚拟 ns。指令的 TCG helper 在 host 上花了更久，
也不会自动使 `QEMU_CLOCK_VIRTUAL` 多走。特殊指令/事件可能退出 TB 或改变
设备状态，但那是正确性和调度边界，不是按真实 latency 加权计时。

真实硬件也不存在可以从 ISA opcode 单独查出的固定耗时：DIV 依实现而异；
load/store 受 cache、TLB、DRAM、争用影响；分支受预测状态影响；乱序、超标量
可使多条指令并行完成。TCG 运行的是另一套 host 指令，其执行耗时还受 host
cache、编译器、内核调度干扰。拿 host wall time 直接当目标 CPU 周期同样
不成立。QEMU 的约定是一把**可重复的逻辑尺**，不是微架构性能模型。

例如两个程序都执行 100 万条 guest 指令，一个全是加法，另一个含大量访存：
在 `shift=3` 且没有空闲 warp、外部事件的理想条件下，两者都推进约 8 ms 的
虚拟时间，尽管 host 完成它们的秒数和真实 A57 完成它们的周期数可能完全不同。
因此不要用 icount 评估 IPC、cache miss latency、真实硬件吞吐量或电源管理
时序；需要这些指标要用相应微架构模拟器或硬件测量。

## WFI/WFE、host cond wait 与“没有指令时”的时间

AArch64 `WFI` 会让 vCPU 停止执行 guest 指令。若时间只能由执行指令推进，
CPU 等 timer IRQ、timer 又等时钟推进，就会死锁。QEMU 的空闲路径如下：

```text
guest WFI
  HELPER(wfi)                                target/arm/tcg/op_helper.c
    halted = 1；退出 CPU 执行循环
  rr_cpu_thread_fn()                         accel/tcg/tcg-accel-ops-rr.c
    全部 vCPU idle → 通知 main loop
    rr_wait_io_event()
      qemu_cond_wait_bql()                    host 线程等待唤醒

main_loop_wait()                              util/main-loop.c
  icount_start_warp_timer()                   accel/tcg/icount-common.c
    查询最近的非外部虚拟 timer deadline
    推进 qemu_icount_bias 或安排 warp timer
```

固定 shift 有两种空闲策略：

| 选项 | 全部 vCPU 空闲且有虚拟 timer 时 |
| --- | --- |
| 默认 `sleep=on` | 用 `QEMU_CLOCK_VIRTUAL_RT` 的 host 时间安排 warp timer；到期或被事件唤醒时，将经过的时间加到 `qemu_icount_bias`，兼顾外部真实时间节奏 |
| `sleep=off` | 直接把到下一虚拟 timer 的 `deadline` 加入 `qemu_icount_bias` 并通知时钟，无须等 host 时间；没有 active timer 时不会凭空推进 |

注意 warp **不增加 `qemu_icount`**：CPU 休眠时没有执行 guest 指令。它只让
`QEMU_CLOCK_VIRTUAL` 跨过无指令的等待区间；timer callback 随后拉高 PPI，
唤醒 CPU，后续指令继续计数。默认 `sleep=on` 因空闲期间参考 host 时间，不能
声称所有 guest 可见时间都只由指令数确定。`shift=auto` 还会参考 host/VM
时间差动态改 `icount_time_shift`，也不适合把“每条恒定 ns”当不变量。

此 QEMU checkout 的 AArch64 `WFE` 要单独看：

```text
HELPER(wfe)                                 target/arm/tcg/op_helper.c
  HELPER(yield)
    退出本轮执行，让其它 vCPU 获得运行机会
    不设置 halted=1
```

它**不**像 `WFI` 那样令 CPU 睡到事件；`translate-a64.c` 也注明尚未完整模拟
WFE/SEV。所以不能把所有“降频/等待”指令都等同于 host cond wait。`WFIT` 另有
`wfxt_timer` 超时和 halt 逻辑。

## icount 模式中 arch timer 到期由谁执行

可以把原来的方案理解成“host 时钟走到预约时间，main loop 醒来处理超时”；
icount 改成“**先算出还允许 CPU 执行多少条 guest 指令，再让 CPU 恰好走到预约
时间**”。预约仍在原有 `QEMUTimer` 队列里，不存在另造一套 arch timer 回调。
这里“异步”的是 guest 视角：Linux 正在执行，随后 timer IRQ 可以到来；
host 执行视角下，到期 callback 通常是共享 vCPU 线程在调度点**同步**调用的，
并非 host timer 信号打断 TB，也非每个 TB 后投递 main loop 事件。

这里两个词有严格含义：

- **预算**：本轮允许当前 vCPU 最多再执行的 guest 指令数，不是 timer 本身
  的计数器。通常先取最近虚拟 timer 距当前虚拟时间的 ns，再按 `2^shift`
  ns/指令向上换算；实现还会考虑更早的 `REALTIME` timer、单线程轮流运行
  的 vCPU 数，并在运行前重新取一次上限。因此，预算不一定恰好等于“最近
  一个 arch timer 超时所需的指令数”。例如 `shift=3`、最近虚拟 timer
  还差 80 ns，初步上限是 10 条；本例配置两个 vCPU 时，
  `icount_percpu_budget()` 会先给当前 vCPU 5 条，让另一个 vCPU 也有机会
  运行。这里除以的是 CPU 总数，并不按当时是否 halted 过滤。

- **调度点**：退出本轮 `tcg_cpu_exec()`、回到 `rr_cpu_thread_fn()` 的 vCPU
  轮转循环，不是仅从一个 `cpu_tb_exec()` 返回。一个 TB 结束后，通常仍在
  `cpu_exec_loop()` 内继续跑下一个 TB。预算用尽时，先在 TB 边界结束本轮
  CPU 执行，调用 `icount_process_data()` 结算；下一轮循环再检查到期 timer。
  如果下一 TB 比剩余预算长，`cpu_loop_exec_tb()` 会安排只覆盖剩余指令数
  的短 TB。这仍不等于每个 TB 结束都进入 timer callback。

**到底怎样判断要回调度层？**要分清“当前 TB 请求退出”和“本轮 vCPU
执行结束”两个判断，不能把 `TB_EXIT_REQUESTED` 直接等同于 timer 到期：

```text
生成的 TB 入口                              accel/tcg/translator.c:gen_tb_start()
  count = icount_decr.u32 - tb->icount
  (int32_t)count < 0 → TB_EXIT_REQUESTED    预算不够，或 high 位要求退出
  否则写回 low，执行 TB

TB 返回 C 执行循环                          accel/tcg/cpu-exec.c:cpu_loop_exec_tb()
  TB_EXIT_REQUESTED 且 high 位要求退出 → 返回内层循环，处理 exit_request
  只是低位额度不够 → icount_update()；按剩余 icount_budget 重装 low/extra
    若剩余条数小于下一 TB → 设置 cflags_next_tb，生成短 TB
    这两种情况都不代表已经返回 rr_cpu_thread_fn()

内层循环下一次检查                      accel/tcg/cpu-exec.c:cpu_handle_interrupt()
  exit_request 为真，或
  icount_exit_request(): low + icount_extra == 0
    → exception_index = EXCP_INTERRUPT
    → cpu_exec_loop() / tcg_cpu_exec() 返回

真正的 vCPU 轮转层                       accel/tcg/tcg-accel-ops-rr.c:rr_cpu_thread_fn()
  icount_process_data()                     结算已执行条数，清空本轮预算字段
  下一轮 icount_handle_deadline()           检查到期 timer
  下一轮 icount_percpu_budget() / icount_prepare_for_run()  重算、装入预算
```

在通常的 icount TB 上，`low + icount_extra == 0` 才是**预算耗尽后退出
本轮 vCPU 执行**的关键判断；`cpu_exit()` 设置的 `exit_request` 则用于
guest 重排更早 timer 等需要提前打断本轮的情况。`icount_exit_request()`
另有 `CF_USE_ICOUNT` 等特殊执行标志的保护条件，完整表达式见源码。

```text
guest 写 CNTP_CVAL_EL0
  gt_recalc_timer() → timer_mod()            原有 timer 队列记录到期虚拟 ns

共享 vCPU 线程准备运行
  从队列取最近 deadline - 当前虚拟 ns
  按 2^shift ns/指令换算成指令预算

TCG 执行 TB
  每个 TB 入口：预算 -= 该 TB 的 guest 指令数
  普通 TB 的预算未耗尽：继续执行；入口不读当前 ns，也不遍历 timer 队列
  预算不足以跑完整个 TB：改用刚好到边界的短 TB

回到 vCPU 调度点
  结算已执行指令 → 虚拟 ns 到达 deadline
  qemu_clock_run_timers() → arm_gt_ptimer_cb() → PPI 30
```

所以你的“每 TB 后检查是否超时”在功能上接近，但 QEMU 把**反复查询时间**
换成了**预先计算预算 + TB 入口的便宜减法**。到边界时才回到 timer 框架查
deadline、取出到期项并运行 callback；若 guest 或设备中途安排了更早的
deadline，且它成为 timer list 的新队首，`timer_mod_ns()` 会通知
`qemu_timer_notify_cb()`，让当前 vCPU 退出 `tcg_cpu_exec()`，重新计算预算。
若新 timer 并非队首，原预算仍会先停在更早的 deadline，不会错过它；若
guest 把原队首推迟而留下一个偏短的旧预算，最多提前退出一次再重算。
arch timer 的 `QEMUTimer`、有序 timer list 和 `arm_gt_ptimer_cb()` 都没有被替换。

以 guest 把 `CNTP_CVAL_EL0` 改到更早为例，**代码没有原地改写正在递减的
`icount_decr`**，而是让这轮执行提前结束、下一轮重新装入预算：

```text
gt_cval_write() → gt_recalc_timer()          target/arm/helper.c
  timer_mod() → timer_mod_ns()               util/qemu-timer.c
    重排有序 timer list；若新项成为队首，timerlist_rearm()
      qemu_timer_notify_cb()                 system/cpu-timers.c
        当前在 vCPU 线程 → cpu_exit(current_cpu)
          exit_request=true；TCG kick 令后续 TB 入口退出

tcg_cpu_exec() 返回 rr_cpu_thread_fn()       accel/tcg/tcg-accel-ops-rr.c
  icount_process_data()                     结算实际执行的指令
  下一轮 icount_get_limit()                  按新队首重新计算上限
  icount_prepare_for_run()                   将新预算装入 icount_decr
```

`target/arm/cpu.c` 始终用 `timer_new(QEMU_CLOCK_VIRTUAL, 16,
arm_gt_ptimer_cb, cpu)` 创建物理 timer。guest 写 CVAL 后，
`gt_recalc_timer()` 仍用 `timer_mod()` 按 counter tick 安排它；
`util/qemu-timer.c:timer_mod()` 将 tick 乘以 16 ns，存进
`QEMU_CLOCK_VIRTUAL` 的有序 timer list。改变的是**谁推动虚拟时钟、谁选择运行
timer list 的时机**，不是 timer API 或 callback 本身。

一次运行中的时序如下。假设当前虚拟时间距 CVAL 还有 80 ns，`shift=3`
时对应 10 条 guest 指令的预算；若 TB 含 3 条指令，执行它后还剩 7 条，
无需逐 TB 遍历 timer list：

```text
rr_cpu_thread_fn()                            accel/tcg/tcg-accel-ops-rr.c
  icount_percpu_budget()
    icount_get_limit()                       accel/tcg/tcg-accel-ops-icount.c
      qemu_clock_deadline_ns_all(VIRTUAL)    最近 timer 距今多少虚拟 ns
      icount_round(deadline)                 换成 guest 指令预算
  icount_prepare_for_run()                   装入 icount_decr / icount_extra
  tcg_cpu_exec()
    TB 入口：预算 -= tb->icount              accel/tcg/translator.c
    预算足够 → 执行 TB；下一 TB 重复入口检查
    预算恰好耗尽 → 退出 cpu_exec_loop()     accel/tcg/cpu-exec.c
    下一 TB 比预算长 → 重译短 TB，到边界再退出
  icount_process_data()                     把已执行指令结算到 qemu_icount

rr_cpu_thread_fn()                            accel/tcg/tcg-accel-ops-rr.c
  icount_handle_deadline()                   accel/tcg/tcg-accel-ops-icount.c
    deadline == 0 → icount_notify_aio_contexts()
  或 icount_prepare_for_run()
    新预算 == 0 → icount_notify_aio_contexts()  本次 GDB 命中这条路径

icount_notify_aio_contexts()                 accel/tcg/tcg-accel-ops-icount.c
  qemu_clock_notify(QEMU_CLOCK_VIRTUAL)     通知该时钟的各个 timer list
  qemu_clock_run_timers(QEMU_CLOCK_VIRTUAL)
    timerlist_run_timers()                   util/qemu-timer.c
      arm_gt_ptimer_cb()                    target/arm/helper.c
        gt_recalc_timer() → gt_update_irq() → GIC PPI 30
```

这两个操作在 `icount_notify_aio_contexts()` 中是连续的，但职责不同：

```c
qemu_clock_notify(QEMU_CLOCK_VIRTUAL);     /* 通知关联的 timer list */
qemu_clock_run_timers(QEMU_CLOCK_VIRTUAL); /* 在当前线程运行主 list 的到期 cb */
```

上面的 80 ns 示例只说明预算换算；两个 vCPU 的每核时间片、其它更早的 timer、
中途新增 deadline、I/O 与异常都可能让本轮提前结束。预算不是在每个 TB 结束
重新读取全部 timer；TB 入口的减法和退出检查是便宜的快路径。`cpu_exec_loop()`
在预算为零时退出，`icount_process_data()` 结账；后续的 vCPU 调度会再次检查
deadline。若进入 `icount_prepare_for_run()` 时预算已经为零，它也会直接在该
线程运行到期 timer。`timerlist_run_timers()` 读取新的虚拟 ns，取出所有已到期项，再
调用原来保存的 callback。

`arm_gt_ptimer_cb()` 属于主 `QEMU_CLOCK_VIRTUAL` timer list，到期
通常由共享 TCG vCPU 线程同步调用。`qemu_clock_notify()` 还会遍历这只时钟的
其它 timer list，唤醒关联的 AioContext。主 timer list 的通知回调是
`system/cpu-timers.c` 中的 `qemu_timer_notify_cb()`。guest 改写 CVAL 且新的
timer 成为列表最早项时，会走下面的重新通知路径：

```text
gt_recalc_timer()                            target/arm/helper.c
  timer_mod()                                util/qemu-timer.c
    timer_mod_ns()
      最早 deadline 改变 → timerlist_rearm()
        timerlist_notify()
          qemu_timer_notify_cb()             system/cpu-timers.c
            调用线程是 vCPU → cpu_exit(current_cpu)，重算预算
            调用线程不是 vCPU → async_run_on_cpu()，唤醒可能 halted 的 vCPU
```

这个通知回调的职责是**重算或唤醒**，不是直接调用 `arm_gt_ptimer_cb()`。
全部 vCPU 都因 WFI 等原因 idle 时，`rr_cpu_thread_fn()` 另外使用
`qemu_notify_event()` 唤醒 main loop，让它启动前文的 clock warp；这是
main loop 在 icount 下参与 arch timer 的关键场景。

不开 icount 时，main loop 的 poll timeout 可包含 `QEMU_CLOCK_VIRTUAL`
deadline，并在 `qemu_clock_run_all_timers()` 中运行虚拟 timer。开 icount 后，
`qemu_clock_use_for_deadline()` 把虚拟时钟排除在 host poll deadline 和
`qemu_clock_run_all_timers()` 的常规循环之外，因为 host 睡眠时长不能决定
guest 走过了几条指令。main loop 仍处理 I/O、其它时钟和全 idle 时的 clock
warp；此时 warp 推进 `qemu_icount_bias`，通知 vCPU 再处理到期的虚拟 timer。
前文 GDB 实测栈中的 `icount_prepare_for_run → icount_notify_aio_contexts →
qemu_clock_run_timers → arm_gt_ptimer_cb` 也证实 callback 是在 vCPU 线程运行。

## 可复现的 mini-virt 观察

保持本 profile 的三个 build owner 都为 `aarch64/mini-virt`。以下命令沿用
`vm/aarch64/mini-virt/run.sh` 的 kernel/DTB/initrd 参数，只加 icount 与 ARM
timer trace；从仓库根目录运行。trace 可能很大，观察后可移除 `-trace`
或缩短运行时间。

```sh
timeout 18s qemu/build/qemu-system-aarch64 \
  -machine mini-virt -accel tcg,thread=single -icount shift=3,sleep=off \
  -smp 2 -m 4G -nographic \
  -kernel linux/build/arch/arm64/boot/Image \
  -dtb linux/build/arch/arm64/boot/dts/demo/mini-virt.dtb \
  -initrd busybox/build/initramfs.cpio.gz \
  -append 'console=ttyAMA0 earlycon=pl011,0x09000000 rdinit=/init panic=-1 sec.fault_test=0' \
  -trace enable=arm_gt_cval_write \
  -trace enable=arm_gt_ctl_write \
  -trace enable=arm_gt_recalc \
  -trace enable=arm_gt_update_irq \
  -trace file=/tmp/syslab-icount.trace
```

本次运行观察到 Linux 输出 `arch_timer: cp15 timer(s) running at 62.50MHz
(phys)`、`clocksource: Switched to clocksource arch_sys_counter`、CPU1 启动，
最终进入 `[/]#` 的 BusyBox shell。trace 中相邻的关键事件如下（`timer 0`
是 `GTIMER_PHYS`）：

```text
arm_gt_cval_write gt_cval_write: timer 0 value 0x1d81dde
arm_gt_ctl_write gt_ctl_write: timer 0 value 0x1
arm_gt_recalc gt recalc: timer 0 next tick 0x1d81dde
arm_gt_update_irq gt_update_irq: timer 0 irqstate 0
arm_gt_recalc gt recalc: timer 0 next tick 0xffffffffffffffff
arm_gt_update_irq gt_update_irq: timer 0 irqstate 1
arm_gt_ctl_write gt_ctl_write: timer 0 value 0x7
arm_gt_update_irq gt_update_irq: timer 0 irqstate 0
```

这证明此运行中 CVAL 被安排、timer 到期拉高输出、guest 后续处理将输出清除。
trace 本身不记录 `qemu_icount` 数值；“每指令 8 ns”和预算机制来自上面的
QEMU 源码，不应把该 trace 当成逐指令测量。下面是带 debug info 的当前
QEMU build，执行以下 GDB 命令得到的真实输出：

```sh
gdb -q -batch -ex 'set pagination off' -ex 'break arm_gt_ptimer_cb' \
  -ex run -ex 'bt 12' --args qemu/build/qemu-system-aarch64 \
  -machine mini-virt -accel tcg,thread=single -icount shift=3,sleep=off \
  -smp 2 -m 4G -display none -serial null -monitor none \
  -kernel linux/build/arch/arm64/boot/Image \
  -dtb linux/build/arch/arm64/boot/dts/demo/mini-virt.dtb \
  -initrd busybox/build/initramfs.cpio.gz \
  -append 'console=ttyAMA0 earlycon=pl011,0x09000000 rdinit=/init panic=-1 sec.fault_test=0'
```

GDB 原始输出:

```text
Breakpoint 1 at 0x9f7240: file ../target/arm/helper.c, line 1987.
[Thread debugging using libthread_db enabled]
Using host libthread_db library "/lib/x86_64-linux-gnu/libthread_db.so.1".
[New Thread 0x7ffff698d6c0 (LWP 21575)]
[New Thread 0x7ffff5f1a6c0 (LWP 21576)]
[Switching to Thread 0x7ffff5f1a6c0 (LWP 21576)]

Thread 3 "qemu-system-aar" hit Breakpoint 1, arm_gt_ptimer_cb (opaque=0x555557f4a060) at ../target/arm/helper.c:1987
1987	    ARMCPU *cpu = opaque;
#0  arm_gt_ptimer_cb (opaque=0x555557f4a060) at ../target/arm/helper.c:1987
#1  0x000055555657bce4 in timerlist_run_timers (timer_list=0x555557b9c800) at ../util/qemu-timer.c:563
#2  0x000055555657bd9a in qemu_clock_run_timers (type=QEMU_CLOCK_VIRTUAL) at ../util/qemu-timer.c:577
#3  0x0000555555ec6d33 in icount_notify_aio_contexts () at ../accel/tcg/tcg-accel-ops-icount.c:73
#4  0x0000555555ec6f28 in icount_prepare_for_run (cpu=0x555558014520, cpu_budget=1) at ../accel/tcg/tcg-accel-ops-icount.c:130
#5  0x0000555555ec7e69 in rr_cpu_thread_fn (arg=0x555557f4a060) at ../accel/tcg/tcg-accel-ops-rr.c:283
#6  0x000055555655af29 in qemu_thread_start (args=0x555557fed3e0) at ../util/qemu-thread-posix.c:393
#7  0x00007ffff729cb84 in start_thread (arg=<optimized out>) at ./nptl/pthread_create.c:447
#8  0x00007ffff7329ecc in clone3 () at ../sysdeps/unix/sysv/linux/x86_64/clone3.S:78
```

这次 callback 是共享 TCG vCPU 线程在预算为零时主动运行的，不是 host
main loop 的 poll timeout 直接触发。另用 `-accel tcg,thread=multi -icount
shift=3` 实测以退出码 1 拒绝，提示 `No MTTCG when icount is enabled`。
若要在自己的 build 上看数值，可进一步在 `icount_update_locked` 下断点，
查看 `executed`、`qemu_icount` 和 `qemu_icount_bias`。

再在相同启动参数下断于 `icount_notify_aio_contexts()`，GDB 的现场输出
直接显示：main loop 此刻在 `ppoll`，运行 timer 的调用来自 vCPU 线程；
`qemu_icount` 已累计 guest 指令，`shift` 为 3。这里的断点在函数入口，
不是每个 TB 的末尾。下面是 `info threads`、`bt 8` 和两条 `print` 的
原样输出：

```text
Thread 3 "qemu-system-aar" hit Breakpoint 1, icount_notify_aio_contexts () at ../accel/tcg/tcg-accel-ops-icount.c:72
72	    qemu_clock_notify(QEMU_CLOCK_VIRTUAL);
  Id   Target Id                                           Frame
  1    Thread 0x7ffff698ed40 (LWP 32409) "qemu-system-aar" 0x00007ffff731bcd0 in __GI_ppoll (fds=0x5555583f9cc0, nfds=4, timeout=<optimized out>, sigmask=0x0) at ../sysdeps/unix/sysv/linux/ppoll.c:42
  2    Thread 0x7ffff698d6c0 (LWP 32412) "qemu-system-aar" syscall () at ../sysdeps/unix/sysv/linux/x86_64/syscall.S:38
* 3    Thread 0x7ffff5f1a6c0 (LWP 32413) "qemu-system-aar" icount_notify_aio_contexts () at ../accel/tcg/tcg-accel-ops-icount.c:72
#0  icount_notify_aio_contexts () at ../accel/tcg/tcg-accel-ops-icount.c:72
#1  0x0000555555ec6f28 in icount_prepare_for_run (cpu=0x555558014520, cpu_budget=1) at ../accel/tcg/tcg-accel-ops-icount.c:130
#2  0x0000555555ec7e69 in rr_cpu_thread_fn (arg=0x555557f4a060) at ../accel/tcg/tcg-accel-ops-rr.c:283
#3  0x000055555655af29 in qemu_thread_start (args=0x555557fed3e0) at ../util/qemu-thread-posix.c:393
#4  0x00007ffff729cb84 in start_thread (arg=<optimized out>) at ./nptl/pthread_create.c:447
#5  0x00007ffff7329ecc in clone3 () at ../sysdeps/unix/sysv/linux/x86_64/clone3.S:78
$1 = 12500000
$2 = 3
```

## 确定性到底能保证什么、何时值得付出速度

固定 `shift` 让“相同初态、相同 guest 指令与事件顺序”对应相同虚拟时间；
单线程执行给双核 mini-virt 的 vCPU 一个明确先后顺序；`sleep=off` 使全部
vCPU 空闲时的 timer 跳转不依赖 host 等待时长。这很适合 timer/IRQ 边界 bug
复现、设备模型和驱动竞态定位、测试中稳定的超时注入，以及 QEMU 的
record/replay：记录外部输入和非确定事件后，可在相同指令进度重放，便于追查
“仅偶发一次”的故障。

边界也必须明确：`-icount` **单独**不是整台 VM 的完整确定性保证；网络、磁盘、
用户输入、host 设备响应、外部 QEMU timer 等需要固定输入或 record/replay。
`sleep=on` 的空闲 warp 与 `shift=auto` 还会参考 host 时间。icount 提供可控的
guest 指令时间坐标和事件插入点；要实现整机精确重放，还须控制这些外部来源。

### 源码导航

| 问题 | 入口 |
| --- | --- |
| 选项与 shift、sleep、warp | `accel/tcg/icount-common.c`、`qemu-options.hx` |
| 单线程和每核预算 | `accel/tcg/tcg-accel-ops-rr.c`、`tcg-accel-ops-icount.c` |
| TB 指令数与计数扣减 | `accel/tcg/translator.c`、`cpu-exec.c`、`translate-all.c` |
| 虚拟时钟与 host 时钟 | `util/qemu-timer.c`、`system/cpus.c`、`system/cpu-timers.c` |
| WFI/WFE | `target/arm/tcg/op_helper.c`、`translate-a64.c` |
| ARM counter/timer/IRQ | `target/arm/helper.c`、`target/arm/cpu.c`、`hw/arm/mini-virt.c` |
