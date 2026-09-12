# mini-virt PSCI：启动从核与 CPU 上下电

## PSCI 是什么

PSCI（Power State Coordination Interface）是 Arm 定义的 power management
firmware ABI. 它的两端通常是 non-secure OS 和 EL3 platform firmware，例如 Linux
和 TF-A.

这不表示所有 Arm 系统都必须有 EL3 bootloader，否则 CPU 就无法上电：

- EL3 是 ARMv8-A 的可选 Exception Level；没有实现 EL3 的处理器仍可从最高已实现
  EL 启动。
- 上电复位后的 primary CPU 由 SoC reset logic、Boot ROM 和 boot chain 启动，
  不依赖 OS 先调用 PSCI `CPU_ON`.
- secondary CPU 的启动机制由平台选择，可以是 PSCI，也可以是 spin-table、
  hypervisor 或 SoC-specific power-control interface.
- 若 DT/ACPI 向 OS 声明 PSCI SMC conduit，则必须有一个能接收 `SMC` 并持续提供
  PSCI runtime service 的实现。真实系统中通常是常驻 EL3 的 TF-A BL31 或同类
  secure firmware；早期 bootloader 即使已经退出也不能替代这个 runtime handler.
- 若声明 PSCI HVC conduit，则 PSCI provider 位于 EL2 hypervisor；QEMU mini-virt
  则由 QEMU 直接截获 SMC 并模拟 PSCI，不运行真实 EL3 firmware.

因此关键条件是系统必须提供与所声明 conduit 匹配的 **PSCI runtime provider**，
并不要求它一定是 EL3 bootloader. 最终控制 core 上下电的还可能是 SCP firmware
和 SoC power controller hardware.

小型、封闭或专用 SoC 可以让 EL1 通过平台私有 driver 直接访问 PMU MMIO；通用
Arm64 平台通常使用 PSCI，把硬件差异和敏感电源控制留在 platform firmware.

PSCI 可以理解成“建立在 calling convention 之上的 power-management API”。
SMCCC 是 Arm 官方术语 **SMC Calling Convention** 的缩写，对应规范编号
**DEN 0028**；其中 SMC 是 **Secure Monitor Call**。将缩写完全展开可理解为
“Secure Monitor Call Calling Convention”，但 Arm 官方名称通常写作
“SMC Calling Convention (SMCCC)”。它与 PSCI、ARMv8-A 的分工如下：

- **SMCCC**：规定使用 `SMC` 或 `HVC`，function ID、参数和返回值使用哪些
  通用寄存器，以及 SMC32/SMC64、fast/yielding call、owner 编码和寄存器保存规则。
- **PSCI**：规定 power-management function 及其 ID、参数和返回值，以及
  CPU/power-domain 状态语义、完成条件、并发行为、错误码和能力探测。
- **ARMv8-A**：规定 `SMC`、`HVC`、`ERET` 指令、exception entry/return、
  EL1/EL2/EL3 和相关 system registers.
- **platform firmware**：把 PSCI 语义落实为具体 SoC 的 Power Management Unit
  （PMU，电源管理单元）、reset、clock 和 coherency 操作。

简单介绍一下下面三条 AArch64 exception-control instructions 的作用：

- `SMC`（Secure Monitor Call）：产生同步 exception，通常把请求送到 EL3
  Secure Monitor；PSCI 使用 SMC conduit 时执行 `smc #0`.
- `HVC`（Hypervisor Call）：产生同步 exception，把请求送到 EL2 hypervisor；
  PSCI 使用 HVC conduit 时执行 `hvc #0`.
- `ERET`（Exception Return）：exception handler 处理完成后，根据 `ELR_ELx` 和
  `SPSR_ELx` 恢复 PC 与处理器状态，返回异常前的上下文；PSCI 中通常返回较低 EL
  的调用方。

可以把 `SMC` 类比为 userspace 执行 `SVC` 发起 syscall，但目标 exception level
和服务对象不同：

```text
userspace syscall（普通 Linux 路径）:
  EL0: svc #0
    -> synchronous exception entry
    -> VBAR_EL1 + 0x400                    // lower EL、AArch64、synchronous slot
    -> el0t_64_sync_handler()
    -> el0_svc() -> do_el0_svc()
    -> eret 返回 EL0

PSCI SMC conduit（典型路径）:
  EL1/EL2: smc #0
    -> synchronous exception entry
    -> VBAR_EL3 中的 EL3 vector
    -> Secure Monitor / PSCI firmware handler
    -> eret 返回调用方   // CPU_OFF 成功时不返回
```

`SVC`（Supervisor Call）不是普通 branch，而是 ARMv8-A 明确定义的 synchronous
exception-generating instruction. 执行 `svc #0` 前，AArch64 Linux userspace 已按
syscall ABI 准备：

```text
x8    = __NR_xxx          // syscall number，例如 __NR_write
x0-x5 = arguments         // 最多六个 syscall 参数
svc #0                    // 只触发 SVC exception，不携带 syscall number
```

普通 Linux 中，EL0 的 supervisor 是 EL1，所以 PE 自动完成以下动作：

```text
ELR_EL1  = svc 后一条指令的地址         // syscall 返回 PC
SPSR_EL1 = EL0 原 PSTATE
ESR_EL1.EC = 0x15                     // SVC executed in AArch64
PSTATE.EL = EL1
PC = VBAR_EL1 + 0x400                 // 从 lower EL 进入的 AArch64 synchronous vector
```

`VBAR_EL1` 是 EL1 exception vector table 的基地址，`+0x400` 才是这个来源和异常
类型对应的 slot. Vector entry 先保存通用寄存器形成 `pt_regs`，然后
`el0t_64_sync_handler()` 根据 `ESR_EL1.EC` 识别 `SVC64`，进入 `el0_svc()`；Linux
arm64 从保存的 x8 取得 syscall number 并索引 syscall table. `svc #0` 中的 `#0`
和 `VBAR_EL1 + 0x400` 都不决定具体 syscall number.

所以它“通常到 EL1 vector”是由当前 exception routing 配置和 Linux 的 EL0/EL1
关系决定的，并非任何环境都绝对如此。例如 hypervisor 可以配置 EL2 接管部分
lower-EL exception，此时异常可能先进入 EL2 vector.

发生 `SMC` exception 时，PE 用硬件完成 EL 和 PC 切换，并把返回 PC、原 PSTATE
和 syndrome 分别写入 `ELR_EL3`、`SPSR_EL3` 和 `ESR_EL3`. 进入 EL3 后通常使用
`SP_EL3`，调用方的 SP 保留在原来的 banked stack-pointer register 中；硬件不会
自动把 x0-x30 全部压入内存。EL3 vector 的汇编 prologue 必须根据 SMCCC 保存需要
保留的通用寄存器，然后调用 PSCI dispatcher. 最后由 `ERET` 从 `ELR_EL3` 和
`SPSR_EL3` 恢复返回 PC 与 PSTATE.

这三条都是 AArch64 exception-control instructions，本身不直接切换 power、reset
或 clock；PSCI function ID 和参数仍由 x0-x7 传递。

本文的 PMU 指负责 core/cluster 上下电的 **Power Management Unit 硬件模块**，不是
CPU 性能计数语境中的 Performance Monitoring Unit.

因此 PSCI 不重新定义“第一个参数放 x0”这种底层 calling convention. 它使用
SMCCC 的寄存器约定，再赋予 function ID 和每个参数 PSCI-specific meaning.

### 从 Linux 调用到 firmware 分发

Linux 源码中的函数名只负责在 OS 内部准备 PSCI 参数。Device Tree（DT，设备树）
指定 `method = "smc"` 后，调用最终进入 SMC wrapper：

```text
psci_0_2_cpu_on()
  -> __psci_cpu_on()
  -> invoke_psci_fn()       // DT method = "smc" 时指向 SMC wrapper
  -> arm_smccc_smc()        // 按 AArch64 C ABI 将前四个参数放入 x0-x3
  -> __arm_smccc_smc
```

汇编 wrapper 的核心来自 `arch/arm64/kernel/smccc-call.S`：

```text
进入 __arm_smccc_smc 时：
x0 = function_id                      // 例如 PSCI CPU_ON = 0xC4000003
x1 = arg0                             // target CPU MPIDR affinity
x2 = arg1                             // secondary entry physical address
x3 = arg2                             // context ID
x4-x7 = arg3-arg6                     // 当前 CPU_ON 调用未使用，值为 0
caller stack = struct arm_smccc_res * // 第九个 C 参数，用于接收返回寄存器
```

这里的 `function_id` 不是函数、函数指针或代码地址，而是一个 32-bit dispatch
number. `0xC4000003` 也不是 user-defined value；它是 PSCI v0.2+ 为 `CPU_ON`
规定的标准 SMCCC function ID：

```text
bit[31]     = 1       // fast call
bit[30]     = 1       // SMC64 calling convention
bits[29:24] = 0x04    // owner 4，即 Standard Service（PSCI 所属范围）
bits[23:16] = 0x00    // reserved，必须为 0
bits[15:0]  = 0x0003  // function number 3，即 PSCI CPU_ON

组合结果：1 | 1 | 000100 | 00000000 | 0000000000000011 = 0xC4000003
```

可以把这里理解为：PSCI/SMCCC 面向 kernel 标准化了“请求什么”和“如何传参”，
后续“如何让具体 core 真正上下电”由 platform firmware 与 SoC hardware 自己完成
耦合和配合：

```text
Linux kernel
  -> PSCI/SMCCC 标准 ABI                 // x0-x3 + smc #0
  -> EL3 platform firmware               // 把标准 CPU_ON 语义翻译成平台操作
  -> SoC-specific MMIO 或 SCP mailbox    // firmware 与硬件的厂商接口
  -> PMU/reset/clock/coherency controller // SoC 硬件模块及其状态机
  -> core power-control signals          // power、isolation、reset、clock
```

因此 Linux 不需要知道 PMU address、register bit 或上下电时序。Firmware 负责
cache/coherency 处理、写寄存器或发送 mailbox request，并等待硬件状态；SoC
hardware 负责执行 isolation、clock gate、reset、power gate 和 power-good 检查。
这些 firmware/hardware 接口由 SoC 厂商定义，不属于 PSCI 的统一 ABI.

Linux 当前代码在编译期按下面的宏关系生成该常量：

```c
#define PSCI_0_2_FN_BASE       0x84000000
#define PSCI_0_2_64BIT         0x40000000
#define PSCI_0_2_FN64_BASE     (PSCI_0_2_FN_BASE + PSCI_0_2_64BIT)
#define PSCI_0_2_FN64(n)       (PSCI_0_2_FN64_BASE + (n))
#define PSCI_0_2_FN64_CPU_ON   PSCI_0_2_FN64(3) // 0xC4000003
```

在 arm64 上，`PSCI_FN_NATIVE(0_2, CPU_ON)` 展开为
`PSCI_0_2_FN64_CPU_ON`. Linux 把这个整数放入 x0；QEMU 读取 x0 后按数值分发：

```text
param[0] = env.xregs[0]                       // 读取 guest x0
switch (param[0])
  case QEMU_PSCI_0_2_FN64_CPU_ON:             // 常量也是 0xC4000003
    mpidr      = param[1]                      // guest x1
    entry      = param[2]                      // guest x2
    context_id = param[3]                      // guest x3
    arm_set_cpu_on(mpidr, entry, context_id,
                   target_el, target_aa64)     // 真正执行 QEMU vCPU 上电逻辑
```

所以标准只定义 ID、参数和语义；Linux 与 QEMU 分别实现调用端和服务端代码。
厂商可以在 SMCCC 分配的 SiP/OEM owner 范围定义私有 service，但这里的 PSCI
`CPU_ON` 不属于那种 user-defined service.

```asm
SYM_FUNC_START(__arm_smccc_smc)
    stp     x29, x30, [sp, #-16]!                 // 保存 frame pointer 和返回地址
    mov     x29, sp                               // 建立新的 frame pointer
    smc     #0                                    // caller 已准备 x0-x7；这里只触发 SMC exception
    ldr     x4, [sp, #16]                         // 取 struct arm_smccc_res *
    stp     x0, x1, [x4, #ARM_SMCCC_RES_X0_OFFS]  // 保存 firmware 返回的 x0-x1
    stp     x2, x3, [x4, #ARM_SMCCC_RES_X2_OFFS]  // 保存 firmware 返回的 x2-x3
    ldp     x29, x30, [sp], #16
    ret
SYM_FUNC_END(__arm_smccc_smc)
```

这些寄存器值由 `arm_smccc_smc()` 的 C 调用约定在进入汇编 wrapper 前准备好，
不是由 `smc #0` 填入。第九个 C 参数 `struct arm_smccc_res *` 位于调用者栈上，
所以返回后通过 `[sp, #16]` 取出。成功的
`CPU_ON` 会从 `smc #0` 返回并保存结果；成功的 `CPU_OFF` 按 PSCI 语义不会返回到
后续指令。

实际生成的 `linux/build/vmlinux` 中可以看到：

```text
ffff800080019e28: d4000003  smc #0x0
```

执行 `smc #0` 后，真实 EL3 firmware 根据 x0 中的 SMCCC function ID 分发：

```text
SMC exception entry
  -> SMC dispatcher 读取 x0
  -> 解析 call type、SMC32/SMC64、owner 和 function number
  -> owner = Standard Service 时路由到 PSCI dispatcher
  -> function number = 3 时选择 PSCI CPU_ON
  -> platform CPU_ON implementation
```

mini-virt 没有运行 EL3 firmware，QEMU 直接模拟这一层：

```text
smc #0
  -> arm_is_psci_call()          // 检查 SMC exception 和 psci_conduit
  -> arm_handle_psci_call()
  -> param[0] = env.xregs[0]     // 读取 x0 中的 SMCCC function ID
  -> switch (param[0])
  -> arm_set_cpu_on()
```

因此 `smc #0` 本身不一定是 PSCI. 它只触发 SMC exception；x0 的 function ID
决定所请求的 firmware service. x0 不受支持时，真实 firmware 通常返回
`SMCCC_RET_NOT_SUPPORTED`，QEMU 返回 `QEMU_PSCI_RET_NOT_SUPPORTED`.

#### 为什么是 `smc #0`

A64 的 `SMC` instruction encoding 本身带有一个 16-bit immediate field，因此
汇编语法是 `smc #imm16`. 执行后，PE 会把这个 immediate 放进异常 syndrome 的
ISS 字段；EL3 exception handler 理论上可以从 `ESR_EL3` 读取它。它不是普通函数
参数，也不会自动进入 x0.

SMCCC 规定其标准调用使用 `SMC #0` 或 `HVC #0`. 这样 instruction immediate
只负责选择统一的 SMCCC conduit，具体调用由 x0 中的 32-bit function ID 完整
描述，避免同时存在“imm16 服务号”和“x0 服务号”两套命名空间：

```text
smc #0                          // 固定的 SMCCC exception instruction
x0 = 0xC4000003                 // PSCI CPU_ON function ID
x1 = target_cpu MPIDR affinity  // 目标 PE 的 MPIDR affinity value，本实验 CPU1 为 0x1
x2 = entry address              // 目标 PE 的 guest physical entry address
x3 = context ID                 // 传给目标 PE 入口的上下文值
```

`#0` 与 x0 没有“立即数 0 表示读取 x0”的关系。它们位于两个独立位置：

```text
instruction word = 0xD4000003  // 解码为 smc #0，imm16 位于指令编码内
x0               = 0xC4000003  // 独立的通用寄存器值，标识 PSCI CPU_ON
```

x1 使用与目标 PE 的 `MPIDR_EL1` affinity fields 对应的值，不要求原样复制
`MPIDR_EL1` 的全部非 affinity 状态位。Linux 的 `cpu_logical_map(cpu)` 提供该值；
QEMU 的 `arm_get_cpu_by_id()` 将它与 `ARMCPU.mp_affinity` 比较并找到目标 vCPU.

本次 GDB 现场中的 syndrome 为 `0x5e000000`：高位 EC `0x17` 表示来自 AArch64
执行状态的 SMC，低 16-bit ISS immediate 为 `0x0000`，正好对应 `smc #0`.

返回时，EL3 firmware 把 PSCI result 放入 x0 并执行 `ERET`. 回到 wrapper 后，
`stp x0, x1`、`stp x2, x3` 将 SMCCC 返回寄存器保存到 `struct arm_smccc_res`，
随后 C 代码读取 `res.a0`. `CPU_OFF` 成功时没有这段返回和保存过程，因为规范
要求成功调用不返回。

### PSCI 具体规定什么

PSCI 标准化的 contract 包括：

1. 标准 function，例如 `PSCI_VERSION`、`CPU_SUSPEND`、`CPU_OFF`、`CPU_ON`、
   `AFFINITY_INFO`、`SYSTEM_OFF`、`SYSTEM_RESET` 和 `PSCI_FEATURES`.
2. 每个 function 的输入。`CPU_ON` 输入 target affinity、entry-point physical
   address 和 context ID；PSCI v0.2+ 的 `CPU_OFF` 没有标准输入参数，只作用于
   调用它的 PE.
3. 返回值与错误码，例如 `SUCCESS`、`NOT_SUPPORTED`、`INVALID_PARAMETERS`、
   `DENIED`、`ALREADY_ON`、`ON_PENDING` 和 `INTERNAL_FAILURE`.
4. 调用完成语义。`CPU_OFF` 和成功的 `SYSTEM_OFF` 不返回；`CPU_ON` 返回成功表示
   请求已被接受，目标 PE 随后才到达 entry point.
5. affinity state 的可观察语义，包括 `ON`、`OFF`、`ON_PENDING`，以及
   `AFFINITY_INFO` 的查询规则。
6. CPU_ON/CPU_OFF race、多个调用者操作同一目标时的并发语义。
7. core、cluster 等 power domain 的协调规则，以及 OS-initiated 和
   platform-coordinated power management mode.
8. 版本和可选能力发现。OS 通过 `PSCI_VERSION`、`PSCI_FEATURES` 判断实现能力。

PSCI 不规定 PMU MMIO address、寄存器 bit、clock/reset 时序或 power-gate 电路；
这些属于 platform implementation.

以本实验的 AArch64 `CPU_ON` 为例，PSCI 与 SMCCC 组合后的 ABI 是：

```text
x0 = 0xC4000003              PSCI CPU_ON 的 SMC64 function ID
x1 = target_cpu_affinity     目标 PE affinity；本实验 CPU1 为 1
x2 = entry_point_address     目标 PE 的 guest physical entry address
x3 = context_id              传给目标 PE 入口的上下文值
SMC #0                       进入 SMC conduit；立即数 0 不是 function ID
```

调用方从 `SMC` 返回时在 x0 得到 PSCI return value. 目标 PE不会从调用方的下一条
指令继续执行；它在 firmware/hardware 完成上电后，从 x2 指定的 entry point 进入，
并按 PSCI contract 获得 x3 对应的 context ID.

本实验捕获到的 `CPU_OFF` 寄存器现场是：

```text
x0 = 0x84000002              PSCI CPU_OFF 的 SMC32 function ID
x1 = 0x00010000              Linux wrapper 留下的值；不是 PSCI v0.2 CPU_OFF 参数
SMC #0
```

Linux arm64 当前通过内部 `cpu_off(state)` API 将 power-down state `0x10000` 放入
x1. 对于 PSCI v0.2+ `CPU_OFF`，x1–x3 不是标准 ABI 定义的参数，provider 不应依赖
它们。QEMU 的 CPU_OFF dispatch 也没有读取 `param[1]`，而是根据当前调用 PE 的
MPIDR 执行 `arm_set_cpu_off()`. `CPU_OFF` 没有 target CPU 参数，因为它关闭的就是
执行调用的 PE. 成功路径不返回，不能理解成普通 C 函数“返回 0 后再停止 CPU”；
另一个在线 PE 通过 `AFFINITY_INFO` 观察它是否已经进入 `OFF`.

Linux arm64 先构造 `state`，再由 PSCI wrapper 将它作为第二个 SMCCC register
argument 传入，因此现场表现为 x1=`0x10000`：

```c
/* linux/arch/arm64/kernel/psci.c */
static void cpu_psci_cpu_die(unsigned int cpu)
{
    u32 state = PSCI_POWER_STATE_TYPE_POWER_DOWN <<
                PSCI_0_2_POWER_STATE_TYPE_SHIFT;

    psci_ops.cpu_off(state);
}

/* linux/drivers/firmware/psci/psci.c */
static int __psci_cpu_off(u32 fn, u32 state)
{
    int err;

    err = invoke_psci_fn(fn, state, 0, 0); // x0=fn，x1=state，x2=x3=0
    return psci_to_linux_errno(err);
}

static int psci_0_2_cpu_off(u32 state)
{
    return __psci_cpu_off(PSCI_0_2_FN_CPU_OFF, state);
}
```

QEMU 的 v0.2 CPU_OFF case 没有读取 `param[1]`，而是跳到公共 label，用当前调用
CPU 的 affinity 找到并关闭调用者自身：

```c
/* qemu/target/arm/tcg/psci.c */
case QEMU_PSCI_0_1_FN_CPU_OFF:
case QEMU_PSCI_0_2_FN_CPU_OFF:
    goto cpu_off;

/* ... */

cpu_off:
    ret = arm_set_cpu_off(arm_cpu_mp_affinity(cpu));
    /* successful CPU_OFF does not return to the guest */
    assert(ret == QEMU_ARM_POWERCTL_RET_SUCCESS);
```

PSCI 不是只有软件意义的空接口。它的请求最终必须由实现端落实到 CPU core
以及 SoC 的电源、复位、时钟和一致性硬件。准确说法是：Arm 规定 PSCI 调用的
语义和参数，却不规定一个统一的 PSCI MMIO hardware block. 每款 SoC 的底层
寄存器、握手信号和操作顺序不同，因此 Linux 只调用 PSCI，platform firmware
负责操作芯片专属硬件。

## 从 PSCI 调用到底层 core hardware

以最通用的 ARMv8-A 为边界，CPU 上下电涉及三类不同东西，不能都叫 system register 或汇编指令：

1. `SMC #0` 是 AArch64 instruction. `#0` 是编码在指令里的 `imm16=0`，不表示
   “读取 x0”，也不等于 x0 的 value. 它只触发 Secure Monitor Call exception.
   执行该指令时，x0 中另有一个独立的 32-bit SMCCC function ID；该 value 的
   owner、calling convention 和 function-number fields 决定调用哪个 firmware
   service. PSCI 参数继续放在 x1–x3. `SMC #0` 本身不控制电源、reset 或 clock.
2. `MPIDR_EL1`、`RVBAR_ELx`、`SCR_EL3` 等是 AArch64 system registers.
   它们分别描述 PE affinity、reset 后的架构入口以及安全状态/异常路由。
   它们不是通用的 core power switch. 特别是 `RVBAR_ELx` 的 reset address 是
   implementation-defined 且对普通软件只读；PSCI firmware 不能假定通过写一个
   通用 RVBAR 就能设置任意 secondary entry.
3. 真正改变 voltage、power gate、reset pin 和 clock gate 的是 SoC integration
   中的 power controller 及其硬件接口。这部分不在 ARMv8-A ISA 的统一 programmer's
   model 中，可能是 firmware 可访问的私有 MMIO 寄存器，也可能是发给 System
   Control Processor（SCP，系统控制处理器）的 mailbox/SCMI 请求，最终再由硬件
   状态机和 core 的 power-control signals 完成。SCP 通常是位于 always-on power
   domain 的独立处理器，运行 SoC 厂商提供的 firmware，代替 application processor
   管理 power、clock、reset 和 thermal 等系统资源。它通常是 SoC 内单独的低功耗
   小核或 microcontroller，有自己的 firmware、局部 memory 和 mailbox interface，
   不属于运行 Linux 的 Cortex-A application-core cluster. SCP 描述的是系统控制
   角色，不限定具体 ISA，也不表示它必须位于一颗独立芯片上。

这里的 **mailbox** 是 application processor 与 SCP 之间的硬件通信通道。发送方
通常先把 command 和参数写入 shared memory 或 mailbox register，再写 doorbell
MMIO 通知 SCP；SCP firmware 处理请求、操作 PMU，最后通过 status、response 和
interrupt 通知完成。

**SCMI** 是 Arm **System Control and Management Interface** 的缩写，是运行在
mailbox、shared memory 等 transport 之上的标准 message protocol. 它定义 power
domain、clock、reset、sensor 等资源的 command/response 格式，不是一条 AArch64
instruction，也不是一个固定 MMIO register block. 典型组合是：

```text
EL3 PSCI firmware
  -> Construct SCMI power-domain message   // 标准化 command 和参数
  -> mailbox/shared memory + doorbell MMIO // 把消息送给 SCP
  -> SCP firmware 操作 SoC-specific PMU    // 厂商寄存器和时序
  -> response/interrupt                    // 返回完成状态
```

因此 PSCI 标准化 OS 请求 CPU/system power state 的接口；SCMI 可以继续标准化
firmware 与 SCP 之间的资源管理消息；最终 PMU MMIO 和硬件时序仍由 SoC 实现。

所以这里的 `platform-specific power-management code` 是运行在 EL3 firmware
或 SCP 上的 C/assembly 代码；它读取 PSCI 参数后，按具体 SoC 的 TRM 操作 PMU、
reset、clock 和 coherency 控制。它不是某一个 ARMv8-A system register 的名字，
也不是某一条标准 A64 power-on instruction.

### PSCI 规范定义的软硬件边界

结合 Arm PSCI 与 SMCCC 的分层，把两条边界分开：

```text
边界 A：normal-world software -> PE exception mechanism -> firmware
        x0-x3 + SMC #0 -> EL3 exception entry

边界 B：platform firmware（software）-> SoC integration hardware -> core power domain
        PMU MMIO / SCP message -> SoC power controller（hardware）
        -> power/reset/clock/coherency hardware signals
```

边界 A 是 ARMv8-A architecture 明确定义的软硬件交互。Linux 在 AArch64 状态下
执行 `SMC #0`. PE 将它作为 synchronous exception 处理；典型的 EL3 路径由硬件：

- 把返回地址写入 `ELR_EL3`
- 把调用方 PSTATE 写入 `SPSR_EL3`
- 把异常类型和 syndrome 写入 `ESR_EL3`，其 EC 标识 AArch64 SMC
- 根据 `SCR_EL3`、`HCR_EL2` 和当前 security/exception level 判断路由或 trap
- 从 `VBAR_EL3` 指定的 vector table 取得异常入口并开始执行 EL3 firmware

`SMC #0` 的立即数只进入 syndrome；PSCI/SMCCC function ID 在 `x0`，参数在后续
通用寄存器中。正常可返回的调用由 firmware 把结果写回 `x0` 等寄存器，再执行
`ERET`；硬件从 `SPSR_EL3`/`ELR_EL3` 恢复调用方状态。若 conduit 是 HVC，同一
SMCCC 参数约定使用 `HVC #0`，主要异常边界在 EL2. DT `/psci/method` 选择的是
调用 conduit，不是选择某个 power-controller register bank.

PSCI 对 `CPU_ON`、`CPU_OFF` 和 `AFFINITY_INFO` 的 function semantics、参数、返回值
及并发状态作出约定，但它没有规定 firmware 必须执行哪些 `MSR`，也没有定义一组
`PWR_ON_EL3`/`PWR_OFF_EL3` system registers. 下面这些 system registers 会参与
异常入口或描述 CPU，却没有一个是物理电源开关：

| system register | 在 PSCI 路径中的架构作用 | 不负责什么 |
| --- | --- | --- |
| `SCR_EL3` | 控制 Secure state、SMC disable 和部分异常路由 | 不打开 core power rail |
| `HCR_EL2` | 可控制 EL1 SMC 是否 trap 到 EL2，如 `TSC` | 不控制 clock/reset |
| `VBAR_EL3` | 给出 EL3 exception vector table base | 不是 secondary CPU 的可写启动邮箱 |
| `ELR_EL3` | 保存本次 SMC 返回地址 | 不是目标 CPU_ON entry |
| `SPSR_EL3` | 保存调用者 PSTATE，供 `ERET` 恢复 | 不保存目标 CPU 的完整上电状态 |
| `ESR_EL3` | 描述同步异常类型和 syndrome | 不包含 PMU 完成状态 |
| `MPIDR_EL1` | 报告当前 PE 的 affinity | 不选择或启动目标 PE |
| `RVBAR_ELx` | 报告 reset 后的 implementation-defined 取指地址 | 通常只读，不是通用 boot-address control |

`CPU_ON` 的 target CPU、entry address 和 context ID 来自 SMCCC 参数，不来自写
`MPIDR_EL1` 或 `RVBAR_ELx`. firmware 必须把 entry/context 保存到目标 PE 上电后
可取得的位置，例如 always-on SRAM、firmware per-CPU data 或平台 mailbox.
一种常见实现是目标 PE 先从 implementation-defined reset vector 运行 firmware
trampoline，由它建立 PSCI 要求的初始架构状态，最后跳转到调用方给出的 entry.
具体平台也可能由启动硬件直接支持 programmable boot address，但这仍是平台
寄存器，不是 ARMv8-A 通用 system register. PSCI 强制的是目标 PE 最终以规范
要求的 initial state 从调用方给出的 entry point 开始执行，不强制中间必须经过
reset vector 和 firmware trampoline.

边界 B 是真正改变 core 物理状态的地方，但它属于 **implementation-defined** SoC
integration. 这里的 **SoC power controller 是硬件模块**，通常位于 always-on
power domain，内部 hardware FSM 负责产生并检查电源、复位、时钟和隔离控制信号。
EL3 firmware 的最后一段软件操作通常是：

```text
EL3 firmware（软件）
  -> str/ldr 到 PMU、reset、clock 或 coherency controller 的 MMIO register
        或写 mailbox/doorbell，向 always-on SCP firmware（软件）发出请求
        ↓
SoC power controller（硬件模块）
  -> 内部 hardware FSM 驱动 reset、clock、isolation、power switch
        ↓
CPU/cluster/DSU/互连（硬件模块）
  -> 通过 Q-channel、P-channel 或实现自定义硬件信号完成握手
```

这里的 `str`/`ldr` 是普通 A64 load/store instruction，特殊之处来自目标 physical
address 被 SoC memory map 解码为 device MMIO，而不是来自一条特殊的 power
instruction. 访问顺序还可能需要 `DSB`/`ISB` 等 barrier；barrier 只保证观察和
执行顺序，同样不会自己打开或关闭电源。若由 SCP 控制，应用核写的是 mailbox
或 doorbell，真正访问 PMU 的软件运行在 SCP 上。

从纯 ARMv8-A software programmer's model 看，`WFI` 是 firmware 能执行的最后一个
通用低功耗相关 instruction：PE 表示当前没有工作并等待 wake-up event. 它可以
促成 core 对外给出 standby/quiescent 状态，让 power controller 安全 gate clock
或断电；`WFI` 单独执行仍不等于 `CPU_OFF`. 最终 power switch、power-good、reset、
clock 和 isolation 是硬件 signals/state machine，不是 system-register write.

所以“控制 core 上下电最终的地方”应准确拆成：

| 观察层级 | 最终动作 |
| --- | --- |
| Linux/PSCI caller | 把 FID/参数放入 x0–x3，执行 `SMC #0` 或 `HVC #0` |
| ARMv8-A PE hardware | 完成 exception entry，更新 ELR/SPSR/ESR，跳到 VBAR vector |
| EL3/EL2 firmware | 校验 PSCI 请求，保存 target entry/context，访问 platform control interface |
| SoC software-visible boundary | firmware 对硬件模块的 PMU MMIO 执行 `ldr/str`，或通过 mailbox/SCMI 请求 SCP firmware |
| SoC hardware boundary | **power controller 硬件模块及其 FSM** 与 core/cluster/DSU/互连完成握手，切换 reset/clock/isolation/power |
| 目标 PE CPU_ON | 以平台机制启动，最终以 PSCI 规定状态进入调用方给出的 entry |
| 调用 PE CPU_OFF | 进入不再返回的 quiescent/power-down sequence，停止取指并失去或保留平台规定的状态 |

PSCI 所谓 `OFF` 是协议定义的 affinity state；它要求调用 PE 不再执行以及下一次
`CPU_ON` 按规范重新进入，但规范不要求所有芯片以同一种 transistor-level 方法
达到该状态。芯片可以真正 power-gate，也可以在符合 observable semantics 的前提下
使用 retention 或其他实现。要继续追踪到某个寄存器 bit，分析对象必须从
“ARMv8-A”收窄为具体 Cortex/Neoverse core、DSU/interconnect、SoC 和 TF-A platform
port；仅凭 PSCI 手册无法产生一个通用 MMIO 地址。

这一分层分别来自 [Arm PSCI specification](https://documentation-service.arm.com/static/640f584656ea36189d4e94a4)、
[Arm SMC Calling Convention](https://developer.arm.com/documentation/den0028/e/ARM_DEN0028B_SMC_Calling_Convention.pdf)、
[Arm GICv3/v4 software overview](https://developer.arm.com/-/media/Arm%20Developer%20Community/PDF/Learn%20the%20Architecture/GICv3_v4_overview.pdf?revision=65f91645-cd52-4795-952b-f01095ff5ef8)
以及具体 processor TRM. 前三者分别规定 power-state coordination semantics、
register calling convention/SMC-HVC conduit 和 interrupt-controller power 协作；
processor/SoC TRM 才规定最后的 power-control signals 和寄存器实现。

把这两条边界放回完整调用链：

```text
Linux CPU hotplug / SMP
  -> PSCI ABI: CPU_ON / CPU_OFF / AFFINITY_INFO
  -> SMC 或 HVC instruction，参数放在 x0-x3
  -> EL3 firmware / hypervisor 中的 platform-specific power-management code
  -> SoC PMU/PDC + reset controller + clock controller + coherency fabric + GIC
  -> CPU core 的电源域、reset、clock、启动入口和中断接口
```

若只保留 ARMv8-A 和 GICv3 能统一命名的部分，一次典型调用可以这样理解：

```text
CPU_ON
  Linux: x0=CPU_ON, x1=target MPIDR, x2=entry PA, x3=context ID
  Linux: SMC #0
  EL3 firmware: 保存 entry/context 到 platform mailbox 或 firmware memory
  EL3 firmware: 通过 SoC-specific MMIO/SCP request 打开 power、clock、reset
  target PE: 从 implementation-defined reset address 开始执行 firmware trampoline
  trampoline: 恢复规定的 architectural state，跳到 PSCI entry PA
  target Linux: secondary_entry

CPU_OFF
  Linux: 停止调度，迁移中断，处理 per-CPU timer/GIC/cache 等 OS 状态
  calling PE: x0=CPU_OFF; x1-x3 不属于 PSCI v0.2+ CPU_OFF 的标准参数; SMC #0
  EL3 firmware: 完成 platform-specific coherency/cache/power-domain sequencing
  calling PE: 常见实现进入 WFI，等待外部 power controller 完成 clock/power gate
  another PE: AFFINITY_INFO 查询 firmware 维护或硬件反馈的 OFF 状态
```

这里的 `WFI` 也是 AArch64 instruction，但准确含义是 Wait For Interrupt：它允许
PE 停止执行并等待唤醒事件。`WFI` 自身不保证断电；只执行 `WFI` 通常仍可被 IRQ
唤醒。只有平台 power controller 同时执行 isolation、clock gate、power gate 等
操作时，才形成真正的 power-down. 具体 core implementation 还可能提供外部
Q-channel/P-channel 或其他 implementation-defined 握手信号，但这些是 RTL/SoC
集成接口，不是软件通过 `MRS`/`MSR` 访问的 ARMv8-A system register.

GICv3 又是另一个边界。`GICR_WAKER` 是每个 Redistributor 的 MMIO register；
`ProcessorSleep`/`ChildrenAsleep` 用于让 GIC quiesce 对应 PE 的中断转发。
`ICC_*_EL1` 是通过 `MRS`/`MSR` 访问的 GIC CPU-interface system registers.
它们控制 IRQ/FIQ 的投递和应答，却不直接切断 CPU voltage 或 clock. GIC 可以向
外部 power controller 发出 wake request，实际唤醒仍由 power controller 完成。

最后一层不是一个单独的 PSCI 外设，通常由以下硬件资源共同完成：

| 硬件资源 | CPU_ON 时的典型作用 | CPU_OFF 时的典型作用 |
| --- | --- | --- |
| **PMU/PDC 或 power controller（硬件模块）** | 打开 core/cluster power domain，等待 power-good，解除 isolation | 请求 power-down，设置 isolation，关闭 power domain |
| reset controller | 保持目标 core reset，待电源和时钟稳定后解除 reset | 在平台要求的时机重新 assert reset |
| clock controller | 打开 core/cluster clock，解除 clock gate | gate core clock，可能进一步关闭 cluster clock |
| boot-address register、mailbox 或 reset vector | 写入 secondary entry，或令 reset vector 先进入固件 trampoline | 通常不负责发起下电，但保存下一次启动所需状态 |
| coherency fabric，例如 CCI/CCN/CMN | 将 core/cluster 接入 coherent domain | 在 cache 和内存状态满足平台协议后退出 coherent domain |
| GIC redistributor / CPU interface | 恢复该 CPU 的 SGI、PPI 和 interrupt interface | quiesce per-CPU interrupt state，避免再向停机 core 投递工作 |
| CPU core 本身 | 从 reset 状态开始取指，在指定 EL 和入口执行 | 停止执行；具体 silicon 可能通过 WFI 与 PMU 握手进入断电序列 |

表中的动作和先后次序只是常见实现构成，不是 PSCI 规定的通用寄存器流程。
例如某个平台可能通过 memory-mapped PMU 寄存器控制电源，另一个平台可能把请求
发给独立的 system-control processor. 某些动作由 Linux hotplug 状态机提前完成，
某些由 EL3 firmware 完成，还有些由硬件状态机在收到请求后自动完成。只有结合
具体 SoC 的 TRM、firmware platform port 和 power-controller driver，才能写出
该芯片准确的 MMIO 地址、bit 定义和时序。

`CPU_ON` 的关键硬件结果是：目标 affinity 对应的 core 获得电源和时钟、离开
reset/coherency 隔离，并从 PSCI 参数指定的 entry address 开始执行；context ID
作为入口寄存器值传入。`CPU_OFF` 的关键结果是：调用它的 core 在完成 OS 和
firmware 要求的 quiesce 后停止取指并进入平台定义的断电状态。调用成功后
`CPU_OFF` 不返回。`AFFINITY_INFO` 则让另一个在线 core 查询平台观察到的状态，
它不等同于读取某个由 Arm 统一规定的 power-status register.

PSCI 的标准化价值正在这里：Linux 不需要包含每款 SoC 的 PMU、reset、clock 和
coherency 控制序列；这些强平台相关且通常需要 secure privilege 的操作留在
firmware. Linux 只看 `cpu_operations` 和 PSCI return code.

## mini-virt 在哪里替代了真实硬件

本实验使用 QEMU TCG 和内置 PSCI 仿真，无需加载 TF-A. guest 执行 `SMC #0` 后，
QEMU 截获异常并直接执行 host C 代码，相当于把“EL3 firmware + SoC power
controller”合并成一个简化模型：

这里要区分 **direct-boot stub** 和 **PSCI provider**：

1. QEMU 的 `arm_load_kernel()` 确实把 `bootloader_aarch64[]` 中硬编码的少量
   AArch64 instruction words 写入 guest RAM. CPU0 reset 后通过 TCG 执行这个
   stub；它只设置 DTB 参数并 `br` 到 Linux kernel entry，不实现 PSCI.
2. 启用 PSCI 时，secondary CPU 初始为 `start-powered-off`，QEMU 不写
   `smpboot[]` secondary boot stub. `CPU_ON` 的 host C 回调 reset CPU1、设置
   `PC=secondary_entry`，然后让 CPU1 直接从 Linux secondary entry 开始执行。
3. 每次 PSCI 调用时，guest Linux 自己执行真实的 AArch64 `smc #0` instruction，
   所以这一条指令仍经过 TCG translate/execute；但后续 PSCI service 不执行任何
   guest EL3 firmware binary.

具体执行边界是：

```text
guest Linux instruction: smc #0
  -> trans_SMC()                                      // TCG 翻译 SMC
  -> gen_helper_pre_smc() + EXCP_SMC                  // 形成同步异常并离开当前 TB
  -> cpu_exec_loop()
  -> arm_cpu_do_interrupt()
  -> arm_is_psci_call()                               // 匹配配置的 SMC conduit
  -> arm_handle_psci_call()                           // host C 读取 env.xregs[0..3]
  -> arm_set_cpu_on/off() -- host C function          // 直接修改模拟 vCPU 状态
  -> 返回 guest                                       // 可返回的 PSCI function
```

`arm_cpu_do_interrupt()` 命中内置 PSCI 后直接调用 handler 并 `return`，不会继续
执行通常的模拟 exception entry，也不会把模拟 PC 跳到 `VBAR_EL3` 中的 guest
firmware vector. 也就是说，`smc #0` 之前的 Linux 指令和这条 SMC 本身经过 TCG；
PSCI dispatch、power-state 修改和 CPU_ON/OFF 则直接在 host C 中模拟。

QEMU 的 core 上下电本质上由 **vCPU execution state** 和 **模拟 architectural
state** 两部分共同表达，并不是 host OS 的真正 CPU power operation：

```text
CPU_OFF:
  ARMCPU.power_state = PSCI_OFF       // PSCI 协议状态
  CPUState.halted = 1                 // vCPU 不再进入 TCG guest execution
  CPUState.exception_index = EXCP_HLT // 退出当前执行循环
  CPU n/TCG thread -> wait(halt_cond) // MTTCG host thread 仍存在，只是 park/sleep

CPU_ON:
  async_run_on_cpu()                  // work 入队并 kick 已存在的 CPU n/TCG thread
  cpu_reset()                         // reset 通用寄存器、PSTATE 和模拟 system registers
  arm_emulate_firmware_reset()        // 设置目标 EL 及直接启动所需 EL3/EL2 状态
  CPUState.halted = 0                 // 允许恢复 TCG guest execution
  x0 = context_id                     // PSCI 约定的目标核入口参数
  PC = entry                          // Linux secondary_entry
  ARMCPU.power_state = PSCI_ON
```

`arm_emulate_firmware_reset()` 会按 CPU feature 和目标 EL 调整模拟的 `SCR_EL3`、
`CPTR_EL3`、`HCR_EL2`、PSTATE 等状态，例如设置 Non-secure execution、AArch64
execution state 和 HVC enable. 这里是 QEMU 直接替代真实 firmware 完成 reset 后的
architectural setup，不表示 guest 执行了对应的 `MSR` instructions.

因此从 MTTCG host thread 看，OFF/ON 接近 park/wake；QEMU 没有销毁、重建或调用
`pthread_suspend()`. 从 guest CPU model 看，它同时修改 power/halted 状态，并在
上电时重建寄存器状态和入口环境，两部分缺一不可。

Linux guest 不能直接访问 `ARMCPU.power_state`、`CPUState.halted` 或
`CPUState.exception_index`；它们是 QEMU host process 内的 C fields，不在 guest
physical address space，也不是 guest system registers. 主核通过标准接口间接观察：

```text
下电确认：
  Linux CPU0: PSCI AFFINITY_INFO(target_mpidr=1)
    -> smc #0
    -> QEMU arm_handle_psci_call()
    -> 读取 CPU1 ARMCPU.power_state
    -> x0 = PSCI_OFF
    -> Linux cpu_psci_cpu_kill() 确认 firmware 视角的 OFF

上电确认：
  Linux CPU0: PSCI CPU_ON(target_mpidr=1, entry=secondary_entry)
    <- x0 = SUCCESS                     // 只表示 QEMU 接受启动请求
  Linux CPU1: secondary_start_kernel()
    -> set_cpu_online(1, true)           // CPU1 自己更新 Linux cpu_online_mask
    -> complete(&cpu_running)            // 通知等待中的 CPU0
  Linux CPU0: 检查 cpu_online(1)         // 判断 Linux 视角是否真正 online
```

因此 QEMU 的 `power_state` 只通过 PSCI `AFFINITY_INFO` 暴露；`halted` 和
`exception_index` 不直接暴露给 guest. Linux 的 `/sys/devices/system/cpu/online`
来自 kernel 自己维护的 `cpu_online_mask`，不是读取 QEMU field 或某个 MMIO
register. 一个 CPU 即使在 QEMU 中已经是 `PSCI_ON`，若尚未执行到
`set_cpu_online()`，Linux 仍不会把它报告为 online.

Linux 能看到 DT 中的 PSCI compatible/conduit、SMCCC register ABI、return code 和
CPU 状态结果，但无法分辨 provider 背后是真实 EL3 firmware、EL2 hypervisor，
还是 QEMU host C emulation；这正是 PSCI ABI 隔离实现差异的作用。

| 真实硬件效果 | mini-virt/QEMU 中的替代动作 |
| --- | --- |
| core power domain on/off | `ARMCPU.power_state = PSCI_ON/PSCI_OFF` |
| core 开始/停止取指 | `CPUState.halted = 0/1`，TCG vCPU loop 开始执行或进入等待 |
| assert reset 并建立 architectural reset state | `cpu_reset()` |
| firmware 配置目标 execution level | `arm_emulate_firmware_reset()` 修改模拟的 PSTATE 和 system-register state |
| 设置 secondary boot address | `cpu_set_pc(entry)` 写模拟 CPU 的 PC |
| 传递 context ID | 写 `CPUARMState.xregs[0]` |
| 唤醒或停下目标 core | host `qemu_work_item`、`cpu_exit()` 和 vCPU thread event loop |
| 查询 power status | `AFFINITY_INFO` 读取 `ARMCPU.power_state` |

因此本实验能验证 Linux → SMC → QEMU PSCI dispatch → vCPU 启停 → Linux secondary
entry/hotplug 的软件链路，也能观察模拟 CPU 的 architectural state 变化。它没有
PMU/PDC、reset controller 或 clock controller 的 MMIO 模型，没有 voltage rail、
power-good、isolation、clock gate、cache/coherency handshake 和真实功耗变化。
GICv3 确实是本 machine 中独立建模的硬件，CPU 上线时 Linux 会恢复 CPU interface
和 redistributor 状态；但 GIC 不是 PSCI power controller，也不负责打开 core
电源域。

这里的 CPU offline 表示 vCPU 停止执行，不模拟真实断电、电压变化、功耗或上电
时延；本实验也不验证 CPU idle/suspend. 若要研究实际 core power sequencing，
需要选定具体 SoC，并同时分析其 TRM、TF-A platform port 和 QEMU 对应的 PMU/clock/
reset 模型；mini-virt 当前有意没有实现这部分。

规范与背景：[Arm PSCI 规范](https://documentation-service.arm.com/static/640f584656ea36189d4e94a4)、
[Linux CPU hotplug](https://www.kernel.org/doc/html/v5.16/core-api/cpu_hotplug.html)、
[arm64 启动约定](https://www.kernel.org/doc/html/v5.16/arm64/booting.html).
下面的实现说明以本仓库源码为准。

## mini-virt 的接线

- [QEMU machine](../qemu/hw/arm/mini-virt.c)：`mach_virt_init()` 设置
  `bootinfo.psci_conduit = QEMU_PSCI_CONDUIT_SMC`，调用 `arm_load_kernel()`.
- [ARM boot helper](../qemu/hw/arm/boot.c)：设置每个 CPU 的 `psci-conduit`，
  将非主核设为 `start-powered-off`；`arm_load_dtb()` 内的 `fdt_add_psci_node()`
  根据实际 CPU PSCI 配置重建 `/psci`. 因此 guest 使用的 DTB 包含 QEMU 修改，
  不等同于磁盘上的原始 DTB.
- [mini-virt DTS](../linux/arch/arm64/boot/dts/demo/mini-virt.dts)：CPU0/CPU1 的
  MPIDR 分别为 0/1，`device_type = "cpu"`、`enable-method = "psci"`；
  `/psci` 声明 PSCI 1.0/0.2 compatible 和 `method = "smc"`.
  compatible 用于匹配协议族；实际 `PSCI_VERSION` 返回 1.1.
- [内核配置](../vm/aarch64/mini-virt/linux.config)：`CONFIG_SMP=y`、
  `CONFIG_NR_CPUS=2`、`CONFIG_ARM_PSCI_FW=y`、`CONFIG_HOTPLUG_CPU=y`，
  配合 sysfs，提供 `/sys/devices/system/cpu/cpu1/online`.

## 主核启动与从核启动

CPU0 是启动核，由 QEMU direct boot 启动，不会先收到 `CPU_ON(0)`.
`do_cpu_reset()` 经 `arm_emulate_firmware_reset()` 设置启动 EL，将 CPU0 的 PC
设到 RAM 中的 loader stub；stub 跳到 Linux Image. 当前 Cortex-A57 提供 EL2，
Linux 启动日志会显示 CPU 在 EL2 启动。Linux 在 CPU0 初始化 PSCI、内存、中断和
调度器之后，通过 PSCI 启动 CPU1.

以下是关键逻辑链，跨越 guest/host 边界和异步工作，不是一条连续的 C 栈：

```text
CPU0: Linux setup_arch
  -> psci_dt_init -> psci_0_2_init / psci_1_0_init -> psci_probe
  -> 选择 __invoke_psci_fn_smc，探测 PSCI_VERSION / PSCI_FEATURES

Linux SMP bring-up / 再次 online
  -> __cpu_up -> boot_secondary -> cpu_psci_cpu_boot
  -> psci_ops.cpu_on -> psci_0_2_cpu_on -> __psci_cpu_on
  -> __invoke_psci_fn_smc -> arm_smccc_smc -> SMC #0
---------------- guest / QEMU TCG ----------------
  -> arm_cpu_do_interrupt -> arm_handle_psci_call
  -> arm_set_cpu_on(mpidr, entry, context_id, target_el, aarch64)
  -> async_run_on_cpu
CPU1: arm_set_cpu_on_async_work
  -> cpu_reset -> arm_emulate_firmware_reset
  -> halted = 0，x0 = context_id，cpu_set_pc(entry)，power_state = PSCI_ON
---------------- QEMU / guest -------------------
CPU1: secondary_entry -> secondary_start_kernel -> online / idle 调度
```

Linux 将 `secondary_entry` 的物理地址作为入口，将 context ID 设为 0.
QEMU 的 `arm_set_cpu_on()` 根据 MPIDR 查找 vCPU，并检查入口对齐、CPU 状态和
目标 EL 等；trace 中的 entry 可与 kernel 符号分析对应。API 入口 trace 只证明
调用发生，guest 的 online 状态和启动日志才证明启动完成。

在本实验使用的 MTTCG 模式下，`arm_set_cpu_on()` 不创建或销毁 TCG thread.
每个 vCPU 的 `CPU n/TCG` host thread 在 VM 初始化时已经由
`mttcg_start_vcpu_thread()` 创建：

```text
CPU_OFF:
  arm_set_cpu_off()
    -> async_run_on_cpu(target_cpu, arm_set_cpu_off_async_work)
    -> power_state = PSCI_OFF
    -> halted = 1
    -> exception_index = EXCP_HLT
    -> vCPU thread 在 qemu_process_cpu_events() 中等待 halt_cond

CPU_ON:
  arm_set_cpu_on()
    -> async_run_on_cpu(target_cpu, arm_set_cpu_on_async_work)
       // work 入队并 kick 已存在的目标 vCPU thread
    -> cpu_reset()
    -> arm_emulate_firmware_reset()
    -> halted = 0
    -> x0 = context_id
    -> PC = entry
    -> power_state = PSCI_ON
    -> vCPU thread 离开等待，继续执行 guest code
```

所以从 host thread 的角度看，CPU 下电是把既有 TCG thread **park/sleep** 在条件
变量上，上电是 **wake and resume execution**；不是 `pthread` 意义上的强制
suspend/resume，也不是关掉 thread 后重新创建。若使用 single-thread TCG，则没有
每个 vCPU 独立的 host thread，但 `halted`、work queue 和可运行状态的语义相同。

### Linux 如何确认下电和重新上电

CPU_ON 从请求到 Linux online 有三个不同的完成点：

| 状态 | 含义 |
| --- | --- |
| `CPU_ON == SUCCESS` | provider 已接受请求；本 QEMU 已将异步 work 排队 |
| `ARMCPU.power_state == PSCI_ON` | QEMU 已完成目标 vCPU 的 reset、入口和电源状态设置 |
| `cpu_online(cpu) == true` | 目标 CPU 已执行 Linux bring-up 并设置 online mask |

这三个状态不能互相替代。完整的 Linux hotplug 成功还需要完成后续 online
callbacks.

Linux 区分“CPU 已退出内核”和“物理 power domain 已经 OFF”。执行 offline 时，
目标 CPU 先迁走 task/IRQ、执行 hotplug teardown，并调用 `set_cpu_online(cpu,
false)`. 到达不可返回点后，目标 CPU 在 `cpu_die()` 中调用
`cpuhp_ap_report_dead()`，通知负责本次 hotplug 的控制 CPU：它已经退出内核关键
路径，可以安全清理其余 per-CPU 资源。随后目标 CPU 才调用 PSCI `CPU_OFF`.

`CPU_OFF` 成功时按 PSCI 规范不返回，因此目标 CPU 无法用返回值报告“已断电”。
控制 CPU 在 `cpu_psci_cpu_kill()` 中调用 PSCI `AFFINITY_INFO(target_mpidr, 0)`，
最多轮询约 100 ms；返回 `PSCI_0_2_AFFINITY_LEVEL_OFF` 才说明 firmware 报告该
affinity level 已经 OFF. 超时会打印 `may not have shut down cleanly` warning.

```text
目标 CPU                              控制 CPU
set_cpu_online(false)
cpuhp_ap_report_dead() ------------> cpuhp_bp_sync_dead()
PSCI CPU_OFF                         cpu_psci_cpu_kill()
  // 成功不返回                        -> PSCI AFFINITY_INFO
                                      -> OFF / timeout warning
```

重新 online 时，控制 CPU 调用 `psci_ops.cpu_on(mpidr, secondary_entry)`.
`CPU_ON` 返回 `SUCCESS` 只表示 firmware 接受了启动请求，并不表示目标 CPU 已经
执行 kernel. 控制 CPU 随后最多等待 5 秒；目标 CPU 必须真正从
`secondary_entry` 进入 `secondary_start_kernel()`，完成 GIC、timer 和 CPU
hotplug callbacks，执行 `set_cpu_online(cpu, true)`，再通过 `complete(&cpu_running)`
唤醒控制 CPU. 控制 CPU 最后检查 `cpu_online(cpu)`；未置位则报告 `failed to come
online`，即使先前 PSCI `CPU_ON` 已经返回成功。

```text
控制 CPU                              目标 CPU
PSCI CPU_ON ------------------------> reset -> secondary_entry
  <- SUCCESS                          secondary_start_kernel()
wait_for_completion_timeout()         初始化 GIC/timer/callbacks
                                      set_cpu_online(true)
  <---------------------------------- complete(&cpu_running)
检查 cpu_online(cpu)                  进入 CPUHP_AP_ONLINE_IDLE
```

因此 sysfs 中 `online` 的最终值来自 Linux CPU hotplug 状态机；PSCI
`AFFINITY_INFO` 提供 firmware 视角的下电状态，而目标 CPU 自己设置 online 并发出
completion 才是重新上电完成的内核证据。

## CPU1 下电与重新上电

```text
shell: echo 0 > /sys/devices/system/cpu/cpu1/online
  -> Linux CPU hotplug 状态机，迁移任务并拆除 CPU1 的本地状态
CPU1: cpu_die -> cpu_psci_cpu_die -> psci_ops.cpu_off
  -> psci_0_2_cpu_off -> __psci_cpu_off -> __invoke_psci_fn_smc -> SMC #0
QEMU: arm_cpu_do_interrupt -> arm_handle_psci_call
  -> arm_set_cpu_off(调用者 MPIDR) -> async_run_on_cpu
  -> arm_set_cpu_off_async_work
  -> power_state = PSCI_OFF，halted = 1，exception_index = EXCP_HLT
CPU0: cpu_psci_cpu_kill -> psci_ops.affinity_info -> SMC -> 查询 power_state
  -> 确认 OFF，打印 CPU1 killed
```

`CPU_OFF` 由要下电的 CPU 自己调用，没有目标 CPU 参数；成功后不再返回 guest.
CPU0 可用 `AFFINITY_INFO` 确认完成。`echo 1 > .../cpu1/online` 再走前面的
`CPU_ON` 链路。CPU1 始终存在于 `present`，这里没有创建/删除 QEMU CPU 对象。
本实验保留 CPU0 在线，只操作 CPU1.

## API 与 trace 对照

| 请求 | AArch64 本实验 function ID | 关键 QEMU API |
| --- | --- | --- |
| PSCI_VERSION | `0x84000000` | `arm_handle_psci_call`，返回 1.1 |
| CPU_ON | `0xc4000003` | `arm_set_cpu_on`，异步设置入口并启动目标 CPU |
| CPU_OFF | `0x84000002` | `arm_set_cpu_off`，异步停止调用者 |
| AFFINITY_INFO | `0xc4000004` | 查询目标 `power_state`，ON=0、OFF=1 |
| SYSTEM_OFF | `0x84000008` | `qemu_system_shutdown_request`，随后停止调用者 |

实现入口：

- [PSCI 分发](https://github.com/thisinnocence/qemu/blob/my/v10.2.0/target/arm/tcg/psci.c)
- [电源控制](https://github.com/thisinnocence/qemu/blob/my/v10.2.0/target/arm/arm-powerctl.c)
- [Linux PSCI 固件驱动](https://github.com/thisinnocence/linux/blob/my/v6.9/drivers/firmware/psci/psci.c)
- [arm64 CPU operations](https://github.com/thisinnocence/linux/blob/my/v6.9/arch/arm64/kernel/psci.c)
- [arm64 SMP](https://github.com/thisinnocence/linux/blob/my/v6.9/arch/arm64/kernel/smp.c)

## 最小操作与验收

host：

```sh
cd vm/aarch64/mini-virt
./build-all.sh
PSCI_TRACE=/tmp/mini-virt-psci.trace ./run.sh
```

guest 启动时应看到 `Booting Linux on physical CPU`、PSCI 1.1 探测、
`CPU1: Booted secondary processor` 和两个 CPU 激活的日志。

```sh
cat /sys/devices/system/cpu/online
# 0-1
/psci.sh
# 三轮 CPU1 offline / online，最终 psci test: PASS

# 也可手动操作
echo 0 > /sys/devices/system/cpu/cpu1/online
cat /sys/devices/system/cpu/online
# 0
echo 1 > /sys/devices/system/cpu/cpu1/online
cat /sys/devices/system/cpu/online
# 0-1

# 现有设备在 CPU hotplug 后仍应正常工作
/sec.bin --all
poweroff -f
```

host 查看日志：

```sh
rg 'arm_psci_call|arm_powerctl_set_cpu_(on|off)' /tmp/mini-virt-psci.trace
```

一次启动加 `/psci.sh` 的三轮测试应至少出现四次 `arm_powerctl_set_cpu_on cpu 1`
（启动一次，重新 online 三次）和三次 `arm_powerctl_set_cpu_off cpu 1`.
将相邻 `arm_psci_call` 的 function ID 与上表对应，可确认 SMC 分发和底层 API
都走到；不要把现场 `x1=0x10000` 误解成 CPU 编号或 PSCI v0.2+ 的标准 CPU_OFF
参数，它是 Linux wrapper 留下但 firmware 应忽略的值。`cpuid` 才是调用者。
关机时应出现 SYSTEM_OFF，QEMU 正常退出。

`/psci.sh` 检查 sysfs 的 online/present 状态并在异常退出时尝试恢复 CPU1；
结合 `CPU1 killed` 日志及 host trace 才构成完整的模型与 guest 验证。
若缺少 `cpu1/online`，检查最终 `linux/build/.config` 的 HOTPLUG_CPU，
并重新运行 build-all；若仅一个 CPU，检查 `-smp 2`、DTS 和 PSCI 启动日志。

## 本次实测记录

2026-09-12，使用本 profile 的 `build-all.sh` 构建后运行上述流程：

- Linux 6.9.0-mini-virt，探测到 PSCIv1.1、SMC，两个 CPU 均在 EL2 启动
- guest `/psci.sh` 三轮全部通过，退出码 0；每轮出现 `CPU1 killed` 和重新启动日志
- host trace 中 CPU1 上电 4 次、下电 3 次，AFFINITY_INFO 3 次；
  上电入口为本次 Image 的 `0x403bd384`（重新构建后地址可能变化）
- guest 读取运行时 DT 的 `/sys/firmware/devicetree/base/psci/method` 得到 `smc`
- `/sec.bin --all` 验证四 VF 的 DMA/IRQ、独占访问、复位隔离、并发及进程退出清理，
  输出 `sec test: PASS`，退出码 0
- `poweroff -f` 对应 trace 的 `0x84000008`（SYSTEM_OFF），QEMU 退出码 0
- `./vm/verify.sh`、guest 测试脚本的 POSIX sh 语法检查、两个 submodule 的
  `git diff --check` 均通过

## Debug QEMU 与原始证据的采集方式

以下新增记录来自 2026-09-12 的实际 host GDB 会话。QEMU 使用
`--enable-debug`，Meson 配置为 `buildtype=debug`、`debug=true`、
`optimization=0`、`strip=false`、`debug_tcg=true`. 本次已有 build 正是这些
配置，因此增量重编译新增 trace，未切换 profile 或复用 release 配置。
本次 QEMU/Linux 基线分别为 `9ca67e14f955240af5462acd64a70574a5463559` 和
`eeb0bfd464559a5abbbf3be3e55f2174b63795c9`；GDB 为 15.1. QEMU binary 的
SHA-256 是 `1adb8a748268b249bb0effedee9b63e8f817ccca911d5c1870d6bb86ee662598`，
包含本次工作区中尚未提交的 PSCI trace 修改。

[build-qemu.sh](../vm/aarch64/mini-virt/build-qemu.sh) 已固定 `--enable-debug`.
若已有 `qemu/build` 是其他配置，先确认 owner，再只清空 QEMU build：

```sh
# repository root
./vm/build-profile.sh require aarch64/mini-virt qemu/build
rm -rf qemu/build
cd vm/aarch64/mini-virt
./build-all.sh
```

本次捕获的是 **host QEMU 的 C 调用栈**。调试器直接运行 QEMU 可执行文件，
不是连接 QEMU `-s -S` 的 guest GDB stub；后者查看的是 guest Linux 寄存器和栈。
采集时显式指定 `-accel tcg,thread=multi`，因此每个 vCPU 有独立 host 线程。

下面命令从 repository root 执行，使用与 `run.sh` 相同的 kernel、DTB、initramfs
和 bootargs. GDB 文件自动设置断点，命中目标条件后直接执行 `bt`，把返回文本
原样写入 `.bt`；寄存器/结构体查询另存 `.state`，不混入 bt.
每个采集点只记录首次匹配，随后禁用该断点并自动继续：

```sh
gdb -q -batch -x vm/aarch64/mini-virt/tests/psci.gdb --args \
  qemu/build/qemu-system-aarch64 \
  -machine mini-virt -accel tcg,thread=multi -smp 2 -m 4G -nographic \
  -kernel linux/build/arch/arm64/boot/Image \
  -dtb linux/build/arch/arm64/boot/dts/demo/mini-virt.dtb \
  -initrd busybox/build/initramfs.cpio.gz \
  -append 'console=ttyAMA0 earlycon=pl011,0x09000000 rdinit=/init panic=-1 sec.fault_test=0' \
  -trace 'enable=arm_psci_*' -trace 'enable=arm_powerctl_*' \
  -trace enable=arm_cpu_reset -trace enable=arm_emulate_firmware_reset \
  -trace file=/tmp/syslab-psci-gdb/trace.log
```

GDB 脚本会创建 `/tmp/syslab-psci-gdb` 并在其中写入 `.bt`、`.state` 和
`trace.log`. 这些原始结果已经内嵌在本文后续代码块中，不再另存为仓库附件。
复现会覆盖 `/tmp` 中的同名输出；进入 guest shell 后依次执行：

```sh
/psci.sh
echo psci_exit=$?
/sec.bin --all
echo sec_exit=$?
poweroff -f
```

本次结果：三轮 hotplug PASS，`psci_exit=0`；四 VF SEC 回归 PASS，
`sec_exit=0`；GDB 报告 inferior `exited normally`，GDB 命令退出码 0.
断点会改变 host 调度和 guest 可见时间，这些输出用于验证执行路径和状态，
不能用于估计真实 CPU 电源时延。

采集脚本：[`tests/psci.gdb`](../vm/aarch64/mini-virt/tests/psci.gdb).
下文所有 bt 代码块直接来自当次 `.bt` 输出：不删帧、不改地址、不重排、不拼栈，
也保留 libc 栈帧中的 `<optimized out>`. QEMU 自身 `-O0` 不会改变 host libc
的构建方式。前面的箭头图只是逻辑概览，以这里的原始 bt 为实际栈证据。

## 核心数据结构及异步边界

```text
MiniVirtMachineState
├── arm_boot_info
│   ├── psci_conduit
│   └── primary_cpu
└── ARMCPU objects: CPU0 / CPU1
    └── ARMCPU
        ├── CPUState parent_obj                 // 内嵌的通用 vCPU 对象
        │   ├── thread
        │   ├── halted
        │   ├── exception_index
        │   ├── exit_request
        │   ├── work_mutex
        │   └── work_list
        │       └── qemu_work_item
        │           ├── func = arm_set_cpu_off_async_work
        │           └── data = RUN_ON_CPU_NULL
        ├── CPUARMState env                     // 内嵌的 Arm architectural state
        │   ├── xregs[]
        │   ├── pc
        │   ├── pstate
        │   ├── cp15                            // system-register backing state
        │   └── exception
        ├── mp_affinity
        ├── psci_conduit
        └── power_state
```

- `ARMCPU` 内嵌 `CPUState parent_obj` 与 `CPUARMState env`，分别表示通用
  vCPU 执行对象和 Arm 架构寄存器状态。`ARM_CPU(cs)` 是 QOM 类型转换，
  不是另外查出一个物理 CPU. 定义见
  [`target/arm/cpu.h`](../qemu/target/arm/cpu.h) 和
  [`include/hw/core/cpu.h`](../qemu/include/hw/core/cpu.h).
- `ARMCPU.mp_affinity` 是 MPIDR affinity 值；`CPUState.cpu_index` 是 QEMU
  CPU 编号；Linux logical CPU 编号经 `cpu_logical_map()` 映射到 MPIDR.
  本 profile 的 CPU1 三者均为 1，但通用实现不能假设它们总相等。
  `arm_get_cpu_by_id()` 遍历 CPU 对象并比较 `arm_cpu_mp_affinity()`.
- `ARMCPU.power_state` 是 PSCI 的 ON/OFF 等协议状态，受 BQL 保护；
  `CPUState.halted` 控制执行循环是否处于停机等待；`exception_index` 是
  QEMU 执行引擎内部异常编号，不是 Arm 系统寄存器。三者承担不同职责。
- `CPUARMState.xregs[]` 保存 guest 的通用寄存器，`pc`/`pstate` 保存 guest
  程序计数器与处理器状态，`cp15` 也保存 AArch64 system register 的相关状态；
  `env.exception` 记录本次待处理异常的 syndrome、目标 EL 等信息。
- Linux 侧 `cpu_operations` 的 `cpu_boot`/`cpu_die`/`cpu_kill` 指向 arm64
  PSCI 实现；全局 `psci_operations psci_ops` 提供 `cpu_on`/`cpu_off`/
  `affinity_info`. `invoke_psci_fn` 按 DT method 选择 SMC wrapper，最终进入
  [`__arm_smccc_smc`](../linux/arch/arm64/kernel/smccc-call.S).

本次 CPU1 对象地址为 `0x555557ff84c0`. 入队前的 `CPUState *cpu`、
PSCI handler 的 `ARMCPU *cpu` 和回调的 `target_cpu_state` 都指向这个对象。
下文内嵌的 `10-cpu-off-queue` 状态快照记录 work item 地址
`0x7fff6c2c2520`，其 `func=arm_set_cpu_off_async_work`、`data=0`、
`free=true`、`exclusive=false`. 这只是本次 host 地址，重跑可能变化。

请求侧在 `cpu_handle_exception()` 持有 BQL 时调用 Arm `do_interrupt` hook.
`arm_set_cpu_off()` 验证对象与电源状态，然后 `async_run_on_cpu()` 分配
`qemu_work_item`，将回调和参数放入对象；`queue_work_on_cpu()` 在
`work_mutex` 下把它追加到该 CPU 的 FIFO，随后调用 `cpu_exit()`.
`cpu_exit()` 设置 `exit_request` 并 `qemu_cpu_kick()`，使 vCPU 退出当前执行循环。
这些是 host 的队列和唤醒操作，不是向 guest GIC 注入 PSCI IRQ.

即使请求方就是 CPU1 自己，`async_run_on_cpu()` 也排队，不会内联执行回调。
因此真实 bt 分为两段：请求侧仍在 `tcg_cpu_exec()` 内；回调侧已回到
`mttcg_cpu_thread_fn()` 的 `qemu_process_cpu_events()`. 后者调用
`process_queued_cpu_work()` 出队，释放 work mutex，再持有 BQL 执行普通回调。
回调结束后 work item 被释放。CPU_ON 则由 CPU0 排队给 CPU1，携带
`CpuOnInfo { entry, context_id, target_el, target_aa64 }`，由 CPU1 回调完成
reset、寄存器设置、PC 设置和 `PSCI_ON` 状态更新。

当前 QEMU 实现还有一个需要单独理解的 PSCI 状态边界。`arm_set_cpu_on()` 会检查
`PSCI_ON` 和 `PSCI_ON_PENDING`，但它在 `async_run_on_cpu()` 入队前没有把
`power_state` 设置为 `PSCI_ON_PENDING`；异步回调最后才设置 `PSCI_ON`：

```text
CPU_ON 请求侧（持有 BQL）
  检查 target == OFF
  -> async_run_on_cpu()                  // work 入队后 power_state 仍为 OFF
  -> return SUCCESS

目标 vCPU 回调（稍后重新持有 BQL）
  cpu_reset()                            // callback 没有再次检查 target 是否已 ON
  -> 设置目标 EL、context 和 PC
  -> power_state = PSCI_ON
```

因此它没有完整建模 `OFF -> ON_PENDING -> ON`. 如果多个 `CPU_ON` 在第一个回调
执行前都通过 OFF 检查，就可能排入多个上电 work，后续回调可能再次 reset 已启动
的目标。BQL 能避免 `power_state` 发生无保护的 C data race，但不会自动保证完整的
PSCI race semantics. 这个竞态窗口是根据当前源码推导的限制，本实验的三轮串行
hotplug 没有复现或覆盖它。

下电回调入口的现场仍为 `PSCI_ON`、`halted=0`；执行三个赋值后为
`PSCI_OFF`、`halted=1`、`exception_index=65537`. `65537 = 0x10001 = EXCP_HLT`，
它不是 guest 执行了 x86 HLT，也不是向 guest 投递一个 Arm IRQ.
[`arm_cpu_has_work()`](../qemu/target/arm/cpu.c) 的电源状态检查使普通 IRQ
无法把 PSCI_OFF 的 CPU 重新变成 online. host 线程和 CPU 对象仍在；
`cpu_thread_is_idle()` 会优先处理非空 work queue，所以后续 CPU_ON 工作可被执行。

## 软件与硬件接口：每一步究竟经过什么

| 接口 | 本实验的交互位置 | QEMU 对应行为 |
| --- | --- | --- |
| sysfs | userspace 写 `cpu1/online` | 先进入 Linux CPU hotplug 状态机；该文件不是设备寄存器映射 |
| Arm ISA `SMC #0` | Linux `__arm_smccc_smc` | TCG 翻译和异常分发进入内置 PSCI handler |
| 通用寄存器 x0–x3 | x0=function ID；CPU_ON 的 x1=MPIDR、x2=入口 PA、x3=context | handler 读取 `env.xregs[]`；有返回值的请求通过 x0 返回 |
| `MPIDR_EL1` | CPU affinity 身份与 Linux CPU 映射 | 与 CPU 对象的 affinity 对应；它不是写入即可上下电的控制寄存器 |
| `HCR_EL2.TSC`、`SCR_EL3.SMD`、当前 EL | SMC 的架构合法性及路由检查 | `helper_pre_smc()` 检查相关状态；本次最终走 QEMU PSCI conduit |
| `ICC_*_EL1` system registers | Linux GICv3 CPU interface、IPI/SGI、优先级与中断应答 | `MRS`/`MSR` 进入 QEMU GICv3 system register 实现，不承担 PSCI function 分发 |
| GIC MMIO | GICD `0x08000000`；GICR 区域 `0x080a0000` 起，CPU1 redistributor `0x080c0000` | CPU1 启动时 Linux GIC driver 初始化 redistributor 和 SGI/PPI 状态 |
| guest IRQ | scheduler 的跨核协作、timer 与设备完成中断 | GIC 向 CPU 投递 IRQ；PSCI 本身没有专属完成 IRQ |
| host work queue / kick | CPU_OFF 的延迟执行、CPU_ON 的目标线程唤醒 | `qemu_work_item`、BQL、mutex、host 线程唤醒，不是 guest MMIO 或 IPI |

PSCI 调用没有 MMIO base、寄存器窗口或独立 IRQ number. PSCI v0.2+ `CPU_OFF`
没有标准参数；trace 中 x1 的 `0x10000` 是 Linux wrapper 留下且 firmware 忽略的
值，不是目标 MPIDR. 要关闭的 PE 来自当前调用 CPU.
`CPU_ON` 的 x2 是 guest 物理入口地址，不是 host 函数指针。上电时 QEMU 设置
目标 CPU 的 PC，guest 随后从 `secondary_entry` 执行自己的代码。

`SMC #0` 中的立即数 0 不代表 CPU0 或 PSCI function ID；function ID 在 x0.
[`trans_SMC()`](../qemu/target/arm/tcg/translate-a64.c) 生成
`helper_pre_smc()` 和 `EXCP_SMC` 异常路径。TCG JIT 执行 helper 时，原始 bt
可看到 `code_gen_buffer`；离开 TB 后，`cpu_exec_loop()` 经
`cpu_handle_exception()` 调用 `arm_cpu_do_interrupt()`，所以异常分发时的 bt
不会保留此前已经退出的 JIT/helper 栈帧。

本次中断入口现场 `exception_index=13`（EXCP_SMC），syndrome 为
`1577058304 = 0x5e000000`，EC 为 `0x17`，对应 AArch64 SMC，ISS 中立即数为 0.
`env.exception.target_el=3` 是该异常路径的目标信息；随后
`arm_is_psci_call()` 匹配 SMC conduit，直接交给 `arm_handle_psci_call()` 并返回。
因此不能从 `target_el=3` 推断 guest 已进入并运行 EL3 固件。
现场 `vaddress`/`fsr` 并非此 SMC 的参数，不应当按 MMIO fault 地址解读。

CPU_ON 的回调通过 `cpu_reset()` 和 `arm_emulate_firmware_reset()` 设置目标
CPU 的 EL、执行状态和相关 system register 状态；本次目标是 EL2，随后 Linux
进入自己的常规执行环境。日志中 “All CPU(s) started at EL2” 描述的是启动入口，
不表示 Linux 普通代码一直在 EL2 执行。

GIC 的 MMIO/system register 交互在 Linux CPU bring-up/hotplug 协作中发生，
与 PSCI 的固件调用边界不同。例如
[`gic_starting_cpu()`](../linux/drivers/irqchip/irq-gic-v3.c) 调用 `gic_cpu_init()`，
初始化 redistributor MMIO 后再调用 `gic_cpu_sys_reg_init()`. 本文没有对这些
GIC 访问逐条抓 bt；下文的现场证据集中于 SMC、PSCI 分发和电源状态更新。

## 原始 GDB bt

以下各代码块均为原始 bt；相关状态查询统一列在全部 bt 之后。

### 01-primary-reset: CPU0 direct boot 的 reset 入口

```text
#0  do_cpu_reset (opaque=0x555557f2e890) at ../hw/arm/boot.c:657
#1  0x00005555559ef603 in legacy_reset_hold (obj=0x555558303b40, type=RESET_TYPE_COLD) at ../hw/core/reset.c:76
#2  0x00005555563458ae in resettable_phase_hold (obj=0x555558303b40, opaque=0x0, type=RESET_TYPE_COLD) at ../hw/core/resettable.c:162
#3  0x0000555556344bda in resettable_container_child_foreach (obj=0x5555580b7480, cb=0x555556345792 <resettable_phase_hold>, opaque=0x0, type=RESET_TYPE_COLD) at ../hw/core/resetcontainer.c:54
#4  0x00005555563455f5 in resettable_child_foreach (rc=0x555557dc3020, obj=0x5555580b7480, cb=0x555556345792 <resettable_phase_hold>, opaque=0x0, type=RESET_TYPE_COLD) at ../hw/core/resettable.c:92
#5  0x0000555556345853 in resettable_phase_hold (obj=0x5555580b7480, opaque=0x0, type=RESET_TYPE_COLD) at ../hw/core/resettable.c:155
#6  0x000055555634549e in resettable_assert_reset (obj=0x5555580b7480, type=RESET_TYPE_COLD) at ../hw/core/resettable.c:58
#7  0x00005555563453f2 in resettable_reset (obj=0x5555580b7480, type=RESET_TYPE_COLD) at ../hw/core/resettable.c:45
#8  0x00005555559ef971 in qemu_devices_reset (type=RESET_TYPE_COLD) at ../hw/core/reset.c:176
#9  0x0000555555db176a in qemu_system_reset (reason=SHUTDOWN_CAUSE_NONE) at ../system/runstate.c:526
#10 0x00005555559e8261 in qdev_machine_creation_done () at ../hw/core/machine.c:1825
#11 0x0000555555d7c238 in qemu_machine_creation_done (errp=0x555557ad37c0 <error_fatal>) at ../system/vl.c:2784
#12 0x0000555555d7c37b in qmp_x_exit_preconfig (errp=0x555557ad37c0 <error_fatal>) at ../system/vl.c:2812
#13 0x0000555555d7efbc in qemu_init (argc=28, argv=0x7fffffffd1f8) at ../system/vl.c:3850
#14 0x00005555564887fa in main (argc=28, argv=0x7fffffffd1f8) at ../system/main.c:71
```

### 02-cpu-on: CPU0 请求启动 CPU1

```text
#0  arm_set_cpu_on (cpuid=1, entry=1077662596, context_id=0, target_el=2, target_aa64=true) at ../target/arm/arm-powerctl.c:90
#1  0x00005555560216bb in arm_handle_psci_call (cpu=0x555557f2e890) at ../target/arm/tcg/psci.c:154
#2  0x0000555555f58b79 in arm_cpu_do_interrupt (cs=0x555557f2e890) at ../target/arm/helper.c:9510
#3  0x0000555555e9ce32 in cpu_handle_exception (cpu=0x555557f2e890, ret=0x7ffff600c68c) at ../accel/tcg/cpu-exec.c:728
#4  0x0000555555e9d665 in cpu_exec_loop (cpu=0x555557f2e890, sc=0x7ffff600c720) at ../accel/tcg/cpu-exec.c:940
#5  0x0000555555e9d6ef in cpu_exec_setjmp (cpu=0x555557f2e890, sc=0x7ffff600c720) at ../accel/tcg/cpu-exec.c:1018
#6  0x0000555555e9d78c in cpu_exec (cpu=0x555557f2e890) at ../accel/tcg/cpu-exec.c:1044
#7  0x0000555555ec668f in tcg_cpu_exec (cpu=0x555557f2e890) at ../accel/tcg/tcg-accel-ops.c:82
#8  0x0000555555ec7218 in mttcg_cpu_thread_fn (arg=0x555557f2e890) at ../accel/tcg/tcg-accel-ops-mttcg.c:93
#9  0x000055555655af29 in qemu_thread_start (args=0x555557fd1500) at ../util/qemu-thread-posix.c:393
#10 0x00007ffff729cb84 in start_thread (arg=<optimized out>) at ./nptl/pthread_create.c:447
#11 0x00007ffff7329ecc in clone3 () at ../sysdeps/unix/sysv/linux/x86_64/clone3.S:78
```

### 03-cpu-on-callback: CPU1 执行上电回调

```text
#0  arm_set_cpu_on_async_work (target_cpu_state=0x555557ff84c0, data={host_int = 1744981952, host_ulong = 140734938369984, host_ptr = 0x7fff68024fc0, target_ptr = 140734938369984}) at ../target/arm/arm-powerctl.c:52
#1  0x0000555555902dda in process_queued_cpu_work (cpu=0x555557ff84c0) at ../cpu-common.c:378
#2  0x0000555555d81225 in qemu_process_cpu_events_common (cpu=0x555557ff84c0) at ../system/cpus.c:459
#3  0x0000555555d812d3 in qemu_process_cpu_events (cpu=0x555557ff84c0) at ../system/cpus.c:478
#4  0x0000555555ec71ec in mttcg_cpu_thread_fn (arg=0x555557ff84c0) at ../accel/tcg/tcg-accel-ops-mttcg.c:88
#5  0x000055555655af29 in qemu_thread_start (args=0x5555580b3720) at ../util/qemu-thread-posix.c:393
#6  0x00007ffff729cb84 in start_thread (arg=<optimized out>) at ./nptl/pthread_create.c:447
#7  0x00007ffff7329ecc in clone3 () at ../sysdeps/unix/sysv/linux/x86_64/clone3.S:78
```

### 04-cpu-on-complete: CPU1 上电状态已更新

```text
#0  arm_set_cpu_on_async_work (target_cpu_state=0x555557ff84c0, data={host_int = 1744981952, host_ulong = 140734938369984, host_ptr = 0x7fff68024fc0, target_ptr = 140734938369984}) at ../target/arm/arm-powerctl.c:82
#1  0x0000555555902dda in process_queued_cpu_work (cpu=0x555557ff84c0) at ../cpu-common.c:378
#2  0x0000555555d81225 in qemu_process_cpu_events_common (cpu=0x555557ff84c0) at ../system/cpus.c:459
#3  0x0000555555d812d3 in qemu_process_cpu_events (cpu=0x555557ff84c0) at ../system/cpus.c:478
#4  0x0000555555ec71ec in mttcg_cpu_thread_fn (arg=0x555557ff84c0) at ../accel/tcg/tcg-accel-ops-mttcg.c:88
#5  0x000055555655af29 in qemu_thread_start (args=0x5555580b3720) at ../util/qemu-thread-posix.c:393
#6  0x00007ffff729cb84 in start_thread (arg=<optimized out>) at ./nptl/pthread_create.c:447
#7  0x00007ffff7329ecc in clone3 () at ../sysdeps/unix/sysv/linux/x86_64/clone3.S:78
```

### 05-cpu-off-smc: CPU1 执行 SMC 的 TCG helper

```text
#0  helper_pre_smc (env=0x555557ffbfc0, syndrome=1577058304) at ../target/arm/tcg/op_helper.c:1071
#1  0x00007fff7445e80f in code_gen_buffer ()
#2  0x0000555555e9c43b in cpu_tb_exec (cpu=0x555557ff84c0, itb=0x7fffb445e6c0, tb_exit=0x7ffff580b690) at ../accel/tcg/cpu-exec.c:439
#3  0x0000555555e9d28e in cpu_loop_exec_tb (cpu=0x555557ff84c0, tb=0x7fffb445e6c0, pc=18446603338368785944, last_tb=0x7ffff580b698, tb_exit=0x7ffff580b690) at ../accel/tcg/cpu-exec.c:891
#4  0x0000555555e9d61e in cpu_exec_loop (cpu=0x555557ff84c0, sc=0x7ffff580b720) at ../accel/tcg/cpu-exec.c:1001
#5  0x0000555555e9d6ef in cpu_exec_setjmp (cpu=0x555557ff84c0, sc=0x7ffff580b720) at ../accel/tcg/cpu-exec.c:1018
#6  0x0000555555e9d78c in cpu_exec (cpu=0x555557ff84c0) at ../accel/tcg/cpu-exec.c:1044
#7  0x0000555555ec668f in tcg_cpu_exec (cpu=0x555557ff84c0) at ../accel/tcg/tcg-accel-ops.c:82
#8  0x0000555555ec7218 in mttcg_cpu_thread_fn (arg=0x555557ff84c0) at ../accel/tcg/tcg-accel-ops-mttcg.c:93
#9  0x000055555655af29 in qemu_thread_start (args=0x5555580b3720) at ../util/qemu-thread-posix.c:393
#10 0x00007ffff729cb84 in start_thread (arg=<optimized out>) at ./nptl/pthread_create.c:447
#11 0x00007ffff7329ecc in clone3 () at ../sysdeps/unix/sysv/linux/x86_64/clone3.S:78
```

### 06-cpu-off-interrupt: CPU1 的 SMC 异常分发入口

```text
#0  arm_cpu_do_interrupt (cs=0x555557ff84c0) at ../target/arm/helper.c:9492
#1  0x0000555555e9ce32 in cpu_handle_exception (cpu=0x555557ff84c0, ret=0x7ffff580b68c) at ../accel/tcg/cpu-exec.c:728
#2  0x0000555555e9d665 in cpu_exec_loop (cpu=0x555557ff84c0, sc=0x7ffff580b720) at ../accel/tcg/cpu-exec.c:940
#3  0x0000555555e9d6ef in cpu_exec_setjmp (cpu=0x555557ff84c0, sc=0x7ffff580b720) at ../accel/tcg/cpu-exec.c:1018
#4  0x0000555555e9d78c in cpu_exec (cpu=0x555557ff84c0) at ../accel/tcg/cpu-exec.c:1044
#5  0x0000555555ec668f in tcg_cpu_exec (cpu=0x555557ff84c0) at ../accel/tcg/tcg-accel-ops.c:82
#6  0x0000555555ec7218 in mttcg_cpu_thread_fn (arg=0x555557ff84c0) at ../accel/tcg/tcg-accel-ops-mttcg.c:93
#7  0x000055555655af29 in qemu_thread_start (args=0x5555580b3720) at ../util/qemu-thread-posix.c:393
#8  0x00007ffff729cb84 in start_thread (arg=<optimized out>) at ./nptl/pthread_create.c:447
#9  0x00007ffff7329ecc in clone3 () at ../sysdeps/unix/sysv/linux/x86_64/clone3.S:78
```

### 07-cpu-off-dispatch: PSCI handler 入口

```text
#0  arm_handle_psci_call (cpu=0x555557ff84c0) at ../target/arm/tcg/psci.c:59
#1  0x0000555555f58b79 in arm_cpu_do_interrupt (cs=0x555557ff84c0) at ../target/arm/helper.c:9510
#2  0x0000555555e9ce32 in cpu_handle_exception (cpu=0x555557ff84c0, ret=0x7ffff580b68c) at ../accel/tcg/cpu-exec.c:728
#3  0x0000555555e9d665 in cpu_exec_loop (cpu=0x555557ff84c0, sc=0x7ffff580b720) at ../accel/tcg/cpu-exec.c:940
#4  0x0000555555e9d6ef in cpu_exec_setjmp (cpu=0x555557ff84c0, sc=0x7ffff580b720) at ../accel/tcg/cpu-exec.c:1018
#5  0x0000555555e9d78c in cpu_exec (cpu=0x555557ff84c0) at ../accel/tcg/cpu-exec.c:1044
#6  0x0000555555ec668f in tcg_cpu_exec (cpu=0x555557ff84c0) at ../accel/tcg/tcg-accel-ops.c:82
#7  0x0000555555ec7218 in mttcg_cpu_thread_fn (arg=0x555557ff84c0) at ../accel/tcg/tcg-accel-ops-mttcg.c:93
#8  0x000055555655af29 in qemu_thread_start (args=0x5555580b3720) at ../util/qemu-thread-posix.c:393
#9  0x00007ffff729cb84 in start_thread (arg=<optimized out>) at ./nptl/pthread_create.c:447
#10 0x00007ffff7329ecc in clone3 () at ../sysdeps/unix/sysv/linux/x86_64/clone3.S:78
```

### 08-cpu-off: arm_set_cpu_off 入口

```text
#0  arm_set_cpu_off (cpuid=1) at ../target/arm/arm-powerctl.c:256
#1  0x0000555556021833 in arm_handle_psci_call (cpu=0x555557ff84c0) at ../target/arm/tcg/psci.c:223
#2  0x0000555555f58b79 in arm_cpu_do_interrupt (cs=0x555557ff84c0) at ../target/arm/helper.c:9510
#3  0x0000555555e9ce32 in cpu_handle_exception (cpu=0x555557ff84c0, ret=0x7ffff580b68c) at ../accel/tcg/cpu-exec.c:728
#4  0x0000555555e9d665 in cpu_exec_loop (cpu=0x555557ff84c0, sc=0x7ffff580b720) at ../accel/tcg/cpu-exec.c:940
#5  0x0000555555e9d6ef in cpu_exec_setjmp (cpu=0x555557ff84c0, sc=0x7ffff580b720) at ../accel/tcg/cpu-exec.c:1018
#6  0x0000555555e9d78c in cpu_exec (cpu=0x555557ff84c0) at ../accel/tcg/cpu-exec.c:1044
#7  0x0000555555ec668f in tcg_cpu_exec (cpu=0x555557ff84c0) at ../accel/tcg/tcg-accel-ops.c:82
#8  0x0000555555ec7218 in mttcg_cpu_thread_fn (arg=0x555557ff84c0) at ../accel/tcg/tcg-accel-ops-mttcg.c:93
#9  0x000055555655af29 in qemu_thread_start (args=0x5555580b3720) at ../util/qemu-thread-posix.c:393
#10 0x00007ffff729cb84 in start_thread (arg=<optimized out>) at ./nptl/pthread_create.c:447
#11 0x00007ffff7329ecc in clone3 () at ../sysdeps/unix/sysv/linux/x86_64/clone3.S:78
```

### 09-cpu-off-async: 下电请求交给 async_run_on_cpu

```text
#0  async_run_on_cpu (cpu=0x555557ff84c0, func=0x555555f3b5ff <arm_set_cpu_off_async_work>, data={host_int = 0, host_ulong = 0, host_ptr = 0x0, target_ptr = 0}) at ../cpu-common.c:171
#1  0x0000555555f3b7e1 in arm_set_cpu_off (cpuid=1) at ../target/arm/arm-powerctl.c:278
#2  0x0000555556021833 in arm_handle_psci_call (cpu=0x555557ff84c0) at ../target/arm/tcg/psci.c:223
#3  0x0000555555f58b79 in arm_cpu_do_interrupt (cs=0x555557ff84c0) at ../target/arm/helper.c:9510
#4  0x0000555555e9ce32 in cpu_handle_exception (cpu=0x555557ff84c0, ret=0x7ffff580b68c) at ../accel/tcg/cpu-exec.c:728
#5  0x0000555555e9d665 in cpu_exec_loop (cpu=0x555557ff84c0, sc=0x7ffff580b720) at ../accel/tcg/cpu-exec.c:940
#6  0x0000555555e9d6ef in cpu_exec_setjmp (cpu=0x555557ff84c0, sc=0x7ffff580b720) at ../accel/tcg/cpu-exec.c:1018
#7  0x0000555555e9d78c in cpu_exec (cpu=0x555557ff84c0) at ../accel/tcg/cpu-exec.c:1044
#8  0x0000555555ec668f in tcg_cpu_exec (cpu=0x555557ff84c0) at ../accel/tcg/tcg-accel-ops.c:82
#9  0x0000555555ec7218 in mttcg_cpu_thread_fn (arg=0x555557ff84c0) at ../accel/tcg/tcg-accel-ops-mttcg.c:93
#10 0x000055555655af29 in qemu_thread_start (args=0x5555580b3720) at ../util/qemu-thread-posix.c:393
#11 0x00007ffff729cb84 in start_thread (arg=<optimized out>) at ./nptl/pthread_create.c:447
#12 0x00007ffff7329ecc in clone3 () at ../sysdeps/unix/sysv/linux/x86_64/clone3.S:78
```

### 10-cpu-off-queue: 下电 work item 入队入口

```text
#0  queue_work_on_cpu (cpu=0x555557ff84c0, wi=0x7fff6c2c2520) at ../cpu-common.c:135
#1  0x0000555555902630 in async_run_on_cpu (cpu=0x555557ff84c0, func=0x555555f3b5ff <arm_set_cpu_off_async_work>, data={host_int = 0, host_ulong = 0, host_ptr = 0x0, target_ptr = 0}) at ../cpu-common.c:178
#2  0x0000555555f3b7e1 in arm_set_cpu_off (cpuid=1) at ../target/arm/arm-powerctl.c:278
#3  0x0000555556021833 in arm_handle_psci_call (cpu=0x555557ff84c0) at ../target/arm/tcg/psci.c:223
#4  0x0000555555f58b79 in arm_cpu_do_interrupt (cs=0x555557ff84c0) at ../target/arm/helper.c:9510
#5  0x0000555555e9ce32 in cpu_handle_exception (cpu=0x555557ff84c0, ret=0x7ffff580b68c) at ../accel/tcg/cpu-exec.c:728
#6  0x0000555555e9d665 in cpu_exec_loop (cpu=0x555557ff84c0, sc=0x7ffff580b720) at ../accel/tcg/cpu-exec.c:940
#7  0x0000555555e9d6ef in cpu_exec_setjmp (cpu=0x555557ff84c0, sc=0x7ffff580b720) at ../accel/tcg/cpu-exec.c:1018
#8  0x0000555555e9d78c in cpu_exec (cpu=0x555557ff84c0) at ../accel/tcg/cpu-exec.c:1044
#9  0x0000555555ec668f in tcg_cpu_exec (cpu=0x555557ff84c0) at ../accel/tcg/tcg-accel-ops.c:82
#10 0x0000555555ec7218 in mttcg_cpu_thread_fn (arg=0x555557ff84c0) at ../accel/tcg/tcg-accel-ops-mttcg.c:93
#11 0x000055555655af29 in qemu_thread_start (args=0x5555580b3720) at ../util/qemu-thread-posix.c:393
#12 0x00007ffff729cb84 in start_thread (arg=<optimized out>) at ./nptl/pthread_create.c:447
#13 0x00007ffff7329ecc in clone3 () at ../sysdeps/unix/sysv/linux/x86_64/clone3.S:78
```

### 11-cpu-off-callback: 事件循环执行下电回调

```text
#0  arm_set_cpu_off_async_work (target_cpu_state=0x555557ff84c0, data={host_int = 0, host_ulong = 0, host_ptr = 0x0, target_ptr = 0}) at ../target/arm/arm-powerctl.c:243
#1  0x0000555555902dda in process_queued_cpu_work (cpu=0x555557ff84c0) at ../cpu-common.c:378
#2  0x0000555555d81225 in qemu_process_cpu_events_common (cpu=0x555557ff84c0) at ../system/cpus.c:459
#3  0x0000555555d812d3 in qemu_process_cpu_events (cpu=0x555557ff84c0) at ../system/cpus.c:478
#4  0x0000555555ec71ec in mttcg_cpu_thread_fn (arg=0x555557ff84c0) at ../accel/tcg/tcg-accel-ops-mttcg.c:88
#5  0x000055555655af29 in qemu_thread_start (args=0x5555580b3720) at ../util/qemu-thread-posix.c:393
#6  0x00007ffff729cb84 in start_thread (arg=<optimized out>) at ./nptl/pthread_create.c:447
#7  0x00007ffff7329ecc in clone3 () at ../sysdeps/unix/sysv/linux/x86_64/clone3.S:78
```

### 12-cpu-off-complete: 下电状态三个赋值已完成

```text
#0  arm_set_cpu_off_async_work (target_cpu_state=0x555557ff84c0, data={host_int = 0, host_ulong = 0, host_ptr = 0x0, target_ptr = 0}) at ../target/arm/arm-powerctl.c:249
#1  0x0000555555902dda in process_queued_cpu_work (cpu=0x555557ff84c0) at ../cpu-common.c:378
#2  0x0000555555d81225 in qemu_process_cpu_events_common (cpu=0x555557ff84c0) at ../system/cpus.c:459
#3  0x0000555555d812d3 in qemu_process_cpu_events (cpu=0x555557ff84c0) at ../system/cpus.c:478
#4  0x0000555555ec71ec in mttcg_cpu_thread_fn (arg=0x555557ff84c0) at ../accel/tcg/tcg-accel-ops-mttcg.c:88
#5  0x000055555655af29 in qemu_thread_start (args=0x5555580b3720) at ../util/qemu-thread-posix.c:393
#6  0x00007ffff729cb84 in start_thread (arg=<optimized out>) at ./nptl/pthread_create.c:447
#7  0x00007ffff7329ecc in clone3 () at ../sysdeps/unix/sysv/linux/x86_64/clone3.S:78
```

## 原始状态查询：下电前后

以下为独立 GDB 查询输出，未混入或改写上述 bt.

### 10-cpu-off-queue

```text
  Id   Target Id                                           Frame 
  1    Thread 0x7ffff6991d40 (LWP 53430) "qemu-system-aar" (running)
  2    Thread 0x7ffff69906c0 (LWP 53433) "qemu-system-aar" (running)
  3    Thread 0x7ffff600d6c0 (LWP 53434) "qemu-system-aar" (running)
* 4    Thread 0x7ffff580c6c0 (LWP 53435) "qemu-system-aar" (running)
(gdb) p cpu
$14 = (CPUState *) 0x555557ff84c0
(gdb) p wi
$15 = (struct qemu_work_item *) 0x7fff6c2c2520
(gdb) p *wi
$16 = {node = {sqe_next = 0x0}, func = 0x555555f3b5ff <arm_set_cpu_off_async_work>, data = {host_int = 0, host_ulong = 0, host_ptr = 0x0, target_ptr = 0}, free = true, exclusive = false, done = false}
```

### 11-cpu-off-callback

```text
  Id   Target Id                                           Frame 
  1    Thread 0x7ffff6991d40 (LWP 53430) "qemu-system-aar" (running)
  2    Thread 0x7ffff69906c0 (LWP 53433) "qemu-system-aar" (running)
  3    Thread 0x7ffff600d6c0 (LWP 53434) "qemu-system-aar" (running)
* 4    Thread 0x7ffff580c6c0 (LWP 53435) "qemu-system-aar" (running)
(gdb) p target_cpu_state
$17 = (CPUState *) 0x555557ff84c0
(gdb) p ((ARMCPU *)target_cpu_state)->power_state
$18 = PSCI_ON
(gdb) p target_cpu_state->halted
$19 = 0
```

### 12-cpu-off-complete

```text
  Id   Target Id                                           Frame 
  1    Thread 0x7ffff6991d40 (LWP 53430) "qemu-system-aar" (running)
  2    Thread 0x7ffff69906c0 (LWP 53433) "qemu-system-aar" (running)
  3    Thread 0x7ffff600d6c0 (LWP 53434) "qemu-system-aar" (running)
* 4    Thread 0x7ffff580c6c0 (LWP 53435) "qemu-system-aar" (running)
(gdb) p target_cpu->power_state
$20 = PSCI_OFF
(gdb) p target_cpu_state->halted
$21 = 1
(gdb) p target_cpu_state->exception_index
$22 = 65537
```

## 内部关键 trace：整次运行执行流

下面按 function call 层级整理本次 trace:

```text
VM initialization
  arm_cpu_reset cpu=0                                  // 创建后的初始 reset
  arm_cpu_reset cpu=1
  arm_cpu_reset cpu=0
    arm_emulate_firmware_reset cpu=0 target_el=EL2     // CPU0 进入 guest
  arm_cpu_reset cpu=1
    arm_emulate_firmware_reset cpu=1 target_el=EL2     // 设置初始状态，仍等待 PSCI CPU_ON

CPU0: PSCI_VERSION(x0=0x84000000)
  arm_psci_call cpuid=0
  arm_psci_return result=65537                          // 0x00010001 = PSCI 1.1

CPU0: MIGRATE_INFO_TYPE(x0=0x84000006)
  arm_psci_call cpuid=0
  arm_psci_return result=2                              // Trusted OS migration not required

CPU0: PSCI_FEATURES(x0=0x8400000a, feature=0x80000000)
  arm_psci_call cpuid=0                                 // 查询 SMCCC_VERSION
  arm_psci_return result=-1                             // NOT_SUPPORTED
CPU0: PSCI_FEATURES(x0=0x8400000a, feature=0xc4000001)
  arm_psci_call cpuid=0                                 // 查询 CPU_SUSPEND64
  arm_psci_return result=0                              // 支持
CPU0: PSCI_FEATURES(x0=0x8400000a, feature=0xc4000012)
  arm_psci_call cpuid=0                                 // 查询 SYSTEM_RESET2_64
  arm_psci_return result=-1                             // NOT_SUPPORTED

CPU0: CPU_ON(x0=0xc4000003, target=1, entry=0x403bd384, context=0)
  arm_psci_call cpuid=0
    arm_powerctl_set_cpu_on cpu=1 target_el=EL2         // 校验并排队 CPU_ON work
  arm_psci_return result=0                              // 请求已接受
  CPU1 async work
    arm_cpu_reset cpu=1
    arm_emulate_firmware_reset cpu=1 target_el=EL2
    arm_powerctl_cpu_on_complete cpu=1 power_state=0 halted=0 pc=0x403bd384

psci.sh round 1
  CPU1: CPU_OFF(x0=0x84000002, x1=0x10000)
    arm_psci_call cpuid=1
      arm_powerctl_set_cpu_off cpu=1
      arm_powerctl_cpu_off_queued cpu=1                 // async work 已进入 CPU1 work queue
      arm_powerctl_cpu_off_complete cpu=1               // power_state=1 halted=1
        exception_index=65537                            // EXCP_HLT；成功的 CPU_OFF 不返回
  CPU0: AFFINITY_INFO(x0=0xc4000004, target=1, level=0)
    arm_psci_call cpuid=0
    arm_psci_return result=1                             // PSCI_OFF
  CPU0: CPU_ON(x0=0xc4000003, target=1, entry=0x403bd384, context=0)
    arm_psci_call cpuid=0
      arm_powerctl_set_cpu_on cpu=1 target_el=EL2
    arm_psci_return result=0                             // 请求已接受
    CPU1 async work
      arm_cpu_reset cpu=1
      arm_emulate_firmware_reset cpu=1 target_el=EL2
      arm_powerctl_cpu_on_complete cpu=1 power_state=0 halted=0 pc=0x403bd384

psci.sh round 2
  CPU1: CPU_OFF(x0=0x84000002, x1=0x10000)
    arm_psci_call cpuid=1
      arm_powerctl_set_cpu_off cpu=1
      arm_powerctl_cpu_off_queued cpu=1
      arm_powerctl_cpu_off_complete cpu=1 power_state=1 halted=1
        exception_index=65537                            // EXCP_HLT
  CPU0: AFFINITY_INFO(x0=0xc4000004, target=1, level=0)
    arm_psci_call cpuid=0
    arm_psci_return result=1                             // PSCI_OFF
  CPU0: CPU_ON(x0=0xc4000003, target=1, entry=0x403bd384, context=0)
    arm_psci_call cpuid=0
      arm_powerctl_set_cpu_on cpu=1 target_el=EL2
    arm_psci_return result=0
    CPU1 async work
      arm_cpu_reset cpu=1
      arm_emulate_firmware_reset cpu=1 target_el=EL2
      arm_powerctl_cpu_on_complete cpu=1 power_state=0 halted=0 pc=0x403bd384

psci.sh round 3
  CPU1: CPU_OFF(x0=0x84000002, x1=0x10000)
    arm_psci_call cpuid=1
      arm_powerctl_set_cpu_off cpu=1
      arm_powerctl_cpu_off_queued cpu=1
      arm_powerctl_cpu_off_complete cpu=1 power_state=1 halted=1
        exception_index=65537                            // EXCP_HLT
  CPU0: AFFINITY_INFO(x0=0xc4000004, target=1, level=0)
    arm_psci_call cpuid=0
    arm_psci_return result=1                             // PSCI_OFF
  CPU0: CPU_ON(x0=0xc4000003, target=1, entry=0x403bd384, context=0)
    arm_psci_call cpuid=0
      arm_powerctl_set_cpu_on cpu=1 target_el=EL2
    arm_psci_return result=0
    CPU1 async work
      arm_cpu_reset cpu=1
      arm_emulate_firmware_reset cpu=1 target_el=EL2
      arm_powerctl_cpu_on_complete cpu=1 power_state=0 halted=0 pc=0x403bd384

CPU0: SYSTEM_OFF(x0=0x84000008)
  arm_psci_call cpuid=0
    qemu_system_shutdown_request()                       // 请求 QEMU 主循环结束 VM
    arm_powerctl_set_cpu_off cpu=0                       // 复用 cpu_off 路径阻止 SMC 返回
    arm_powerctl_cpu_off_queued cpu=0
    arm_powerctl_cpu_off_complete cpu=0 power_state=1 halted=1
      exception_index=65537                              // EXCP_HLT
```

可按第一轮事件顺序阅读：`CPU_OFF` → `set_cpu_off` → `off_queued` →
`off_complete` → `AFFINITY_INFO result=1`. 这证明请求、实际停机和其他核确认
三个阶段都发生了。`CPU_ON result=0` 是请求被接受；后面的 reset 与
`on_complete` 才是目标核的状态和入口更新。多个 vCPU 的事件可能交错，
不要把一次采集的全局行顺序当作所有调度下的唯一顺序。

`PSCI_VERSION` 返回的十进制 65537，即 `0x00010001`，按 major/minor 编码表示
PSCI 1.1；它恰好与 QEMU 的 `EXCP_HLT` 常量 `0x10001` 数值相同，但二者位于不同
字段，含义无关。这里有三次 `PSCI_FEATURES` 查询：查询 `0x80000000`
（`SMCCC_VERSION`）和 `0xC4000012`（`SYSTEM_RESET2_64`）返回 -1，表示 QEMU
PSCI 实现不支持被查询的 function；查询 `0xC4000001`（`CPU_SUSPEND64`）返回 0，
表示支持。这些启动期 capability probe 不是本轮 CPU hotplug 的结果。

最后的 `x0=0x84000008` 是 `SYSTEM_OFF`. QEMU 先发出 shutdown request，再跳到
与 `CPU_OFF` 共用的 `cpu_off` 路径，将调用者 CPU0 停住，以满足成功的
`SYSTEM_OFF` 不得返回这一语义。因此最后一组 CPU0 `off_queued/off_complete` 属于
整机关机；前面恰好三组 CPU1 OFF 才分别来自
[psci.sh](../vm/aarch64/mini-virt/tests/psci.sh) 的三轮循环。
