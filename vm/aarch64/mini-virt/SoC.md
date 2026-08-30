# mini-virt SoC Design

mini-virt 不是对某块现成开发板的复刻，而是一个用于学习和验证的最小 AArch64 SoC。
它从 Cortex-A57 core、RAM 和 ARM system IP 起步，先打通 Linux 启动闭环，再加入自定义
sec accelerator，最终把 MMIO、interrupt、kernel driver 和 userspace ABI 连成一条可执行、
可观察、可回归的软硬协同链路。

这里的 QEMU model 是 functional model：目标是准确表达 software-visible hardware
contract，使 firmware、kernel 和 userspace 能在 RTL 或 silicon 可用之前参与设计验证。
它适合验证 register、address map、interrupt 和 driver 行为，但不替代 cycle-accurate model、
RTL simulation、FPGA prototype 或 silicon validation。

## SoC Topology

```text
                         mini-virt SoC

  +------------------+       PPI        +----------------------+
  | Cortex-A57 CPU 0 |----------------->|                      |
  +------------------+                  |                      |
                                        |       GICv3          |----> CPU IRQ
  +------------------+       PPI        | Distributor +       |
  | Cortex-A57 CPU 1 |----------------->| Redistributors       |
  +------------------+                  |                      |
           |                            +----------^-----------+
           |                                       |
           | system memory                         | SPI
           v                                       |
  +------------------+       +---------------------+--------------------+
  | 4 GiB RAM        |       |                                          |
  | @ 0x40000000     |       | SPI 1 / INTID 33     SPI 2 / INTID 34   |
  +------------------+       v                                          v
                      +------------------+                    +------------------+
                      | ARM PL011 UART   |                    | sec accelerator  |
                      | @ 0x09000000     |                    | @ 0x0a000000     |
                      +------------------+                    +------------------+
                               |                                      |
                               v                                      v
                         ttyAMA0 console                    /dev/sec + sec.bin
```

architectural timer 是每个 CPU 的 architecture-defined timer，通过 PPI 接入 GICv3。
PSCI 则提供 CPU bring-up 和 power management 调用，使 Linux 能启动第二个 core。QEMU
direct boot 负责装载 kernel、DTB 和 initramfs，不依赖一套完整的 boot firmware。

当前 software-visible address 和 interrupt contract 如下：

| Component | Address or Interrupt | Contract |
| --- | --- | --- |
| GICv3 distributor | `0x08000000-0x0800ffff` | SPI distribution |
| GICv3 redistributor | 从 `0x080a0000` 开始 | per-CPU interrupt state |
| PL011 | `0x09000000-0x09000fff` | SPI 1，INTID 33，`ttyAMA0` |
| sec | `0x0a000000-0x0a0003ff` | SPI 2，INTID 34，level-high |
| RAM | `0x40000000-0x13fffffff` | 4 GiB guest memory |

## Evolution

repository history 展示了这个 SoC 从“能启动”到“能做软硬协同实验”的演进过程。

### 1. Build the Machine Skeleton

最初的 QEMU machine 先定义 Cortex-A57、RAM、GICv3、architectural timer、PL011 和 PSCI。
Linux DTB 描述同一组资源，使 kernel 看到的 hardware topology 与 QEMU 实际创建的 device
一致。

这个阶段的目标不是加入更多 peripheral，而是先回答最基础的问题：

- CPU 能否从正确的 RAM address 启动 kernel？
- GICv3 能否把 timer 和 UART interrupt 路由给 CPU？
- PSCI 能否启动 secondary CPU？
- PL011 能否同时承担 early console 和正式 `ttyAMA0` console？

只有 core、memory、interrupt controller、timer 和 console 一起工作，Linux 才拥有一个
可以继续扩展的最小 ARM platform。

### 2. Close the Linux Boot Loop

`vm/aarch64/mini-virt` 随后把 QEMU、Linux 和 BusyBox 组织为一个完整 VM profile：

```text
QEMU machine
    -> kernel Image + DTB
    -> gzip initramfs
    -> /init as PID 1
    -> devtmpfs/procfs/sysfs
    -> ttyAMA0 BusyBox shell
    -> poweroff
```

这一阶段把“kernel 打出几行 log”提升为完整系统 contract：guest 必须进入交互 shell，
pseudo-filesystem 必须可用，退出 shell 后 PID 1 必须主动关机。构建输出还通过
`.syslab-profile` 绑定 owner，防止另一个 VM profile 的 QEMU、kernel 或 BusyBox artifact
被错误复用。

这一步很重要，因为 accelerator driver 的 probe、device node、userspace test 和 shutdown
都依赖一个稳定的基础系统。如果 boot baseline 本身不可靠，后续 peripheral failure 很难
定位到底来自 device、DT、kernel config 还是 root filesystem。

### 3. Add sec as a Polled MMIO Accelerator

基础 SoC 稳定后，sec 作为第一个 custom accelerator 加入。初版只定义最小 register
contract：

| Register | Offset | Behavior |
| --- | ---: | --- |
| `DATA1` | `0x00` | 第一个 U32 operand |
| `DATA2` | `0x04` | 第二个 U32 operand |
| `CMD` | `0x08` | 写 1 执行 XOR，写 0 清零 result |
| `RESULT` | `0x0c` | 只读 XOR result |

QEMU model 先实现 register behavior，再由 mini-virt 将 1 KiB MMIO window 映射到
`0x0a000000`。此时可以不依赖 Linux driver，直接通过 MMIO access 验证 address decode、
access width、endianness、command semantics 和 result。

从最小的 polled device 开始，可以把 register contract 与 interrupt contract 分开验证。
如果一开始同时加入 DMA、interrupt 和复杂 queue，出现错误时很难判断是 computation、
register state machine、interrupt routing 还是 driver concurrency 的问题。

### 4. Move the Contract into Linux and Userspace

硬件 register behavior 确认后，Linux DT 增加 `syslab,sec` node，platform driver 映射
resource，并通过 miscdevice 创建 `/dev/sec`。UAPI 将 register transaction 转换成稳定的
userspace operation：

```text
write(struct sec_operands) -> DATA1 + DATA2 + CMD=1
read(u32)                 <- RESULT
ioctl(SEC_IOC_CLEAR)      -> CMD=0
```

driver 中的 mutex 保护一次跨多个 register 的 transaction，避免不同进程把 operand 和
command 交叉写入。userspace 不直接依赖 physical address 和 register offset，而是依赖
`/dev/sec` ABI；这为后续修改硬件实现保留了 software abstraction boundary。

`tests/Makefile` 使用 Linux `headers_install` 输出的 sanitized UAPI header 编译静态 AArch64
测试程序。`build-initrd.sh` 只负责调用测试构建并安装 `/sec.bin`，从而保持以下 ownership：

- Linux source 定义 UAPI。
- Linux `headers_install` 导出 userspace 可消费的 header。
- `tests/Makefile` 负责编译测试。
- initramfs script 负责组装 image。

### 5. Upgrade Polling to an Interrupt-Driven Device

最后一步给 sec 加入 SPI 2 level-high interrupt，并新增 `IRQ_STATUS.bit0`：

```text
CMD=1
  -> calculate XOR
  -> update RESULT
  -> set IRQ_STATUS.pending
  -> assert SPI 2
  -> Linux IRQ handler reads RESULT
  -> W1C IRQ_STATUS.pending
  -> deassert SPI 2
```

level interrupt 的核心不是单次 `qemu_set_irq(..., 1)`，而是完整的 assert/ack/deassert
protocol。没有 W1C acknowledge，line 会保持 high，handler 会反复进入；在 pending 清除前
重复发命令，则多个 event 可能合并为同一个 level。

Linux driver 使用 `completion` 将 IRQ event 传回发起命令的 process：`write()` 下发 CMD
后睡眠，IRQ handler 清 source、增加 count 并调用 `complete()`，随后 `write()` 返回。
这既验证了 interrupt 确实到达 kernel，也保证当前同步 ABI 下每个 CMD 对应一次 handler
执行。`SEC_IOC_GET_IRQ_COUNT` 让 userspace test 可以比较前后 count，而不是只根据计算结果
推断中断是否发生。

完整 IRQ contract 和 userspace notification flow 见 [`sec.md`](sec.md)。

## Repository History

下面的 commits 对应主要演进节点，而不是仅按最终目录结构倒推设计：

| Stage | Repository Evidence |
| --- | --- |
| QEMU machine skeleton | QEMU `de9a614ecb` |
| Linux DT skeleton | Linux `22e9ad1bb3ba` |
| Runnable VM profile | syslab `133ebfa` |
| Build、boot、shutdown contract | syslab `cea081b`、`e059394`、`7da4a75` |
| sec MMIO model | QEMU `8cb6a6b0a6`、syslab `2def0e5` |
| sec Linux driver and UAPI | Linux `4e82486cdf8e`、`765a4eca4a66` |
| sec userspace self-test | syslab `7445521`、`ca022e8`、`df134c0` |
| sec level interrupt | QEMU `a9f1b7db36`、Linux `04bd7ece9563`、syslab `cc0a899` |

## Contract Ownership

同一 SoC behavior 会在不同层以不同形式出现。这里保留必要的显式重复，使阅读某一层时
不需要依赖隐藏的 profile DSL，同时通过 end-to-end test 检查这些描述是否一致。

| Layer | File | Ownership |
| --- | --- | --- |
| SoC integration | `qemu/hw/arm/mini-virt.c` | CPU、memory map、system IP、IRQ routing |
| Accelerator model | `qemu/hw/misc/sec.c` | register、command、reset、migration、IRQ state |
| Hardware description | `linux/arch/arm64/boot/dts/demo/mini-virt.dts` | Linux 可发现的 reg/interrupt topology |
| Kernel config | `vm/aarch64/mini-virt/linux.config` | mini-virt 所需的最小 driver set |
| Kernel driver | `linux/drivers/misc/sec.c` | resource、transaction、IRQ 和 userspace boundary |
| UAPI | `linux/include/uapi/linux/sec.h` | application 可依赖的稳定 ABI |
| Userspace test | `vm/aarch64/mini-virt/tests/` | behavior 和 interrupt 的 guest self-test |
| VM orchestration | `vm/aarch64/mini-virt/*.sh` | build order、artifact ownership、boot lifecycle |
| Local contract | `README.md`、`sec.md`、`SoC.md` | profile、device 和方法论的维护边界 |

## Hardware/Software Co-design Method

mini-virt 的价值不只在于实现了一个很小的 SoC，而在于形成了一套可重复的软硬协同方法。

### Start from an Observable Baseline

先建立最小 boot baseline，再加入 custom IP。baseline 的验收点必须可观察：串口 log、
interactive shell、`/proc`、`/sys` 和正常关机。之后每增加一个 feature，只引入一组新的
变量，并保留旧 baseline 作为 regression test。

### Define the Software-visible Contract First

实现 accelerator 前，先明确 software 真正能观察到的接口：

- address、size、alignment 和 endianness；
- register offset、access type、reset value 和 side effect；
- command 何时 accepted、result 何时 valid；
- interrupt type、触发条件、mask/status/ack 和 deassert 条件；
- DMA addressability、coherency 和 ownership，如果 device 使用 DMA；
- concurrency、timeout、error reporting 和 recovery；
- kernel binding、UAPI compatibility 和 userspace synchronization model。

这些 contract 必须同时落实到 QEMU model、machine address/IRQ map、DT、Linux driver、
UAPI、test 和 documentation。它们可以分散在各层实现中，但语义不能漂移。

### Evolve One Boundary at a Time

一个有效的演进顺序是：

1. QEMU model 实现 register behavior。
2. machine 映射 MMIO，并用 `info mtree` 确认 address decode。
3. DT 描述同一 resource，dump DTB 确认最终 binary description。
4. Linux driver 完成 probe、register access 和 serialization。
5. UAPI 与 userspace test 验证 end-to-end behavior。
6. 再加入 interrupt、DMA、queue 或并发等异步机制。

每一步都应该有独立证据。build success 只能证明 source 能组合，不能证明 QEMU hardware、
DT description、kernel interpretation 和 userspace behavior 一致。

### Treat Failures as Contract Evidence

syslab VM profiles 和 mini-virt accelerator 演进中的实际失败，以及设计审查提前发现的
风险，恰好说明了跨层验证的价值：

- `virt` profile 文档要求 GICv3，但 machine option 实际创建了 GICv2，说明文档不能替代
  runtime evidence。
- PID 1 直接返回，kernel 只能 panic，而不是正常 shutdown。
- userspace 直接包含 raw kernel UAPI source，暴露了 kernel-private header dependency。
- sec IRQ 设计如果只有 assert 而没有 acknowledge/deassert，会形成 interrupt storm。
- 不同 VM profile 复用同一 build directory，会混入错误的 machine artifact。

这些问题都不是单独编译某个 component 能发现的。修复后应把约束固化到 README、script、
driver behavior 或 self-test 中，使同类问题从“依赖经验记忆”变成“违反 contract 即失败”。

### Verify the Whole Vertical Slice

一个 accelerator feature 的完成标准应覆盖整条 vertical slice：

| Layer | Evidence |
| --- | --- |
| QEMU model | register behavior、reset、migration、IRQ level |
| Machine integration | `info mtree` address、source/runtime IRQ routing |
| Hardware description | DT source 与 final DTB 中的 reg/interrupt |
| Linux | config、probe log、device node、IRQ handler、`/proc/interrupts` |
| UAPI | sanitized exported header、ABI layout、error semantics |
| Userspace | static self-test、result、IRQ count、exit status |
| System lifecycle | shell remains usable、guest can power off |

## From Software Hotspot to ASIC IP

对于复杂软件系统，将稳定且高负载的核心计算 offload 到 hardware，通常是一条有效的
性能和能效优化路径。QEMU 的关键作用，是在 RTL 尚未完成时提供 software-visible 的
functional model，让真实 Linux、driver、library 和 application 围绕未来硬件接口提前
运行。等 register、DMA、IRQ 和 error handling contract 稳定后，再实现 RTL/ASIC IP 并
接入真实 SoC，可以显著降低“硬件已经完成，软件才发现接口不可用”的风险。

但这不是把 C/C++ algorithm 放进 QEMU 后自动生成 RTL。QEMU 前移的是 system architecture、
hardware/software interface 和 software stack 验证；algorithm microarchitecture、cycle
timing、PPA、CDC、DFT 和 physical implementation 仍属于后续硬件开发。

### Select the Right Workload

是否值得硬化必须从真实 workload profiling 出发，而不是仅凭直觉。适合 offload 的部分
通常具备以下特征：

- 占据显著 CPU time、energy 或 latency budget；
- algorithm 相对稳定，短期不会频繁改变；
- 具有可利用的 parallelism、pipeline 或 data reuse；
- input/output contract 清晰，容易形成独立 transaction；
- 单次 workload 足够大，可以摊薄 syscall、DMA、IRQ 和 scheduling overhead。

端到端收益不能只看 accelerator compute latency，应先建立简单成本模型：

```text
T_total = T_prepare + T_transfer + T_accelerator + T_sync + T_fallback
```

如果 data movement 和 synchronization 比原来的 software compute 更贵，单独加速计算核心
不会带来整体收益。Amdahl's law 同样适用：未被硬化的 software path、serialization 和 I/O
会限制系统最终 speedup。因此 batching、queue depth、memory locality 和 asynchronous API
往往与计算单元本身同等重要。

### Partition Hardware and Software

确定 hotspot 后，先决定 boundary，而不是立即写 RTL：

- hardware 负责稳定、规则且并行度高的 data path；
- driver 负责 resource、DMA mapping、interrupt、timeout、reset 和 recovery；
- userspace library 负责 batching、queue management 和兼容性策略；
- software fallback 保留 reference behavior，也用于 unsupported case 和故障恢复。

boundary 越清楚，QEMU model、RTL 和 software 越容易共享同一份 observable behavior。
对于 sec，XOR 是硬件 data path，Linux driver 将多个 MMIO access 封装为 transaction，
UAPI 则避免 application 直接依赖 physical address。这是一个很小但完整的 partition 示例。

### Design the Interface before RTL

在 QEMU 阶段应尽早确定并验证以下接口，后续 RTL 将它们实现为真实 bus-visible behavior：

| Interface | Questions to Resolve |
| --- | --- |
| Register | width、alignment、reset value、RO/RW/W1C、side effect、version |
| Command | submit、busy、completion、queue depth、ordering、cancel |
| DMA | descriptor、address width、scatter-gather、alignment、ownership |
| Memory | coherent/non-coherent、cache maintenance、barrier、endianness |
| Interrupt | trigger type、status、mask、ack、coalescing、lost event prevention |
| Error | invalid command、DMA fault、timeout、reset、recovery、reporting |
| Discovery | DT/ACPI binding、capability、revision、compatible strategy |
| Security | privilege、IOMMU/SMMU、address isolation、validation of descriptors |

QEMU model 应运行真实 transaction state machine，而不只是对 register 返回固定值。driver
也应从一开始覆盖 timeout、concurrency、reset 和 error path。这样形成的 model 更接近
executable specification，能让 hardware 和 software 团队在 RTL 前共同审查接口。

### Move the Contract into RTL and SoC

contract 稳定后，可以用 RTL 实现同一个 IP，并集成到已有 SoC，但仍需要完成硬件侧工作：

1. 选择 APB、AXI-Lite 或其他 control bus，实现 register block 和 address decode。
2. 设计 compute pipeline、local buffer、queue 和 backpressure。
3. 如果使用 DMA，接入 AXI master、IOMMU/SMMU 和 coherency architecture。
4. 接入 interrupt controller，验证 assert、mask、ack、EOI 和 reset sequence。
5. 处理 clock/reset domain、CDC、power domain 和 low-power state。
6. 完成 lint、formal、simulation、coverage、synthesis、timing、DFT 和 physical verification。
7. 在 FPGA/emulation/RTL simulation 上运行同一 Linux driver 和 userspace tests。

其中 memory ordering 很容易被 functional model 掩盖。真实 weakly ordered ARM system 中，
doorbell、descriptor 和 completion 的可见顺序可能需要 `readl()`/`writel()` semantics、DMA
barrier 和 cache maintenance 配合；non-coherent DMA 还需要明确 cache ownership。QEMU 中
“总是工作”的路径不能替代 RTL 和 platform 上的 ordering/coherency 验证。

### Keep QEMU and RTL as Two Implementations of One Contract

进入 RTL 阶段后，不应丢弃 QEMU model。更有效的方式是让两者长期实现同一份
software-visible contract：

```text
                  +-> QEMU functional model -> Linux/driver/userspace CI
interface spec ---|
                  +-> RTL/FPGA/ASIC IP ------> Linux/driver/userspace validation
```

可复用的内容包括 register test vector、descriptor layout、driver test、error injection、
UAPI test 和 application workload。QEMU 提供快速 software regression，RTL/emulation
验证 cycle-level hardware behavior，FPGA 和 silicon 验证真实 integration。若两边结果不一致，
应回到同一个 interface spec 判断是 QEMU model、RTL 还是 software 偏离 contract。

因此，“functional model → driver/UAPI → RTL IP → SoC integration”确实是一条很好的
软硬协同路线。它不能消除 RTL/ASIC 开发，但能把 software architecture 和 interface risk
显著前移，并让高负载 software 的 hardware offload 从一次性移植变成可持续验证的工程闭环。

## Industry Practice

这套方法在业界已经广泛存在，不过通常使用两个名称描述相邻阶段：

- **Virtual prototyping / pre-silicon software development**：在 silicon 前用 functional
  virtual platform 开发 firmware、OS、driver 和 application。
- **Workload-driven hardware/software co-design**：从 production workload 中识别 hotspot，
  设计专用 accelerator、software stack 和 system integration。

公开的一手资料提供了以下实例：

| Company | Public Practice | Relation to mini-virt |
| --- | --- | --- |
| Arm | [Fast Models](https://www.arm.com/products/development-tools/simulation/fast-models) 提供 CPU 和 system IP 的 programmer's-view model，用于 silicon 前开发 driver、firmware、OS 和 application | 对应 QEMU machine/system IP 与早期 software bring-up |
| Intel | [Simics](https://www.intel.com/content/www/us/en/developer/articles/tool/simics-simulator.html) 被用于 pre-silicon、post-silicon software development、test 和 system integration | 对应可自动化的 full-system functional platform |
| AMD | [Versal QEMU](https://docs.amd.com/r/2024.1-English/ug1304-versal-acap-ssdg/QEMU) 为 Versal、Zynq 和 MicroBlaze 提供 software development platform；[Xilinx QEMU guide](https://docs.amd.com/api/khub/documents/VOM6aBLyjscyBTKoyz7J5Q/content) 还展示 QEMU 与 custom SystemC/TLM/RTL model 的 co-simulation | 最接近 mini-virt 从 QEMU device 扩展到 RTL/SoC 的路径 |
| AWS | [Nitro](https://docs.aws.amazon.com/whitepapers/latest/security-design-of-aws-nitro-system/the-nitro-system-journey.html) 将原本在 Dom0 software 中的 virtualization、network 和 storage 功能逐步拆分并 offload 到 purpose-built Nitro Cards | 对应从复杂系统中分离高负载或关键功能并硬件化 |
| Google | [TPU](https://research.google/pubs/in-datacenter-performance-analysis-of-a-tensor-processing-unit/) 根据 production neural-network inference workload 设计 domain-specific ASIC，并与 TensorFlow software stack 配合 | 对应由真实 workload 驱动 accelerator architecture |
| Meta | [MTIA](https://engineering.fb.com/2024/08/22/ml-applications/meta-mtia-hardware-co-design/) 围绕 recommendation model、PyTorch ecosystem 和 custom silicon 做联合设计 | 对应 hardware、runtime/framework 和 application 共同演进 |

前三类资料直接说明：用 functional virtual platform 在 silicon 前运行真实 software stack、
开发 driver 并做 CI，已经是成熟的工程实践。后三类说明：对于软硬件都能自主设计的公司，
从真实 workload 中选择瓶颈并 offload 到 custom hardware，也是常见的 vertical integration
能力。

这些公开资料并不表示 AWS、Google 或 Meta 一定使用 QEMU 完成上述 accelerator 的全部
pre-silicon flow。实际公司可能组合 QEMU、Simics、Arm Fast Models、SystemC/TLM、RTL
simulation、emulation 和 FPGA。mini-virt 的意义，是使用开源 QEMU 将两类业界方法连接成
一个小而完整的实验：先用 executable functional model 固化 software-visible contract，
再让同一 driver、UAPI 和 workload test 延伸到未来 RTL/ASIC implementation。

## Why QEMU Is Effective for This Work

QEMU 把 hardware contract 变成一个可以和真实 software stack 一起运行的 executable
specification，特别适合以下工作：

- RTL 完成前并行开发 DT、kernel driver、library 和 userspace test。
- 快速调整 address map、register semantics 和 interrupt routing。
- 用 log、monitor、GDB 和 guest observability 定位跨层问题。
- 构造 error、timeout、reset 和 migration 场景，形成稳定 regression。
- 在 CI 中重复启动完整 guest，而不依赖稀缺的 FPGA 或 silicon 环境。

它的边界也必须明确：普通 QEMU device model 不证明 cycle timing、throughput、bus
contention、clock/reset domain crossing、metastability、physical interrupt waveform、
power 或 area，也不会自动证明 RTL 与 model 完全一致。进入 RTL 阶段后，应把相同的
register/interrupt/UAPI contract 和 userspace test 继续复用到 simulation、emulation、
FPGA 和 silicon，QEMU 验证是前移的第一站，而不是最终一站。

## Practical Workflow for the Next Accelerator

在 mini-virt 中加入下一个 custom accelerator 时，可以直接复用以下节奏：

1. 在该 profile 文档中先写 address、register、interrupt 和 userspace contract。
2. 在 QEMU 中实现最小 MMIO model，先验证 polling path。
3. 将 address 和 IRQ 显式加入 mini-virt machine，并同步 DT。
4. 实现最小 Linux platform driver，先完成 probe 和基本 transaction。
5. 定义必要且稳定的 UAPI，不把 physical register layout 直接泄漏给 application。
6. 在 `tests/` 中实现 self-test，由本地 Makefile 负责编译。
7. 增加 interrupt 或 DMA，并明确 pending、ack、timeout、ownership 和 concurrency。
8. 执行 build、monitor、DTB、kernel、userspace 和 shutdown 的全链路验证。
9. 将失败原因和最终行为更新回 local README，而不是只保留在 commit 或 session 中。

这套流程的重点是让 QEMU、hardware description、kernel 和 userspace 围绕同一个 contract
共同演进。模型可以替换，driver 可以重构，验证平台也可以从 QEMU 迁移到 RTL/FPGA，
但 software-visible behavior 和可重复的 end-to-end test 应始终保持连续。
