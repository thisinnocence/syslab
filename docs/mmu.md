# AArch64 MMU：硬件原理、QEMU SoftMMU 与 Linux VA

本文以 `aarch64/mini-virt` 为对象，沿着一条普通 `ldr/str` 的地址路径解释 MMU。
重点是 QEMU 如何把复杂的 ARM 地址翻译、权限与异常语义，提前计算成一个软件
TLB entry，让大多数满足快路径条件的访存只执行一小段 amd64 指令。

源码与实测基线：QEMU `a5ed11b21a9f`（10.2.0）、Linux `31e35d15d55a`
（本地版本字符串 `6.9.0-mini-virt+`），2026-09-19；amd64 Linux host，
Cortex-A57 guest，TCG，mini-virt 的 RAM 为 PA `0x40000000..0x13fffffff`。
Linux 启动实验使用 profile 默认的两个 vCPU；精简访存实验使用同一 machine、两个
vCPU，但 `-accel tcg,thread=single`，只让 CPU0 执行测试，以便隔离调用次数。

贯穿全文先区分三种地址：

```text
AArch64 指令中的 guest VA
  |
  | ARM Stage 1：TTBR/TCR + guest 页表 + 权限
  v
Guest PA                         例如 0x41000000
  |
  | QEMU MemoryRegion/AddressSpace：这段 PA 属于 RAM 还是设备？
  v
Host VA                          例如 RAMBlock.host + 0x01000000
  |
  | amd64 host 自己的 MMU/TLB/页表，仍然存在
  v
Host 物理内存
```

**SoftMMU 快路径缓存的是前两步的合成结果，最后得到的是 host VA，不是 host PA。**
它不让 amd64 硬件读取 ARM 页表，也不为每条 guest 指令调用一次 C 语言 MMU。

阅读顺序：第 1–3 节讲硬件；第 4–10 节展开 QEMU 的结构、代码与真实汇编；
第 11 节说明微测和复现；第 12 节讲 Linux；第 13 节对照 SMMU。

## 1. MMU 究竟接受什么、返回什么

### 1.1 一次访存不只有地址

例如：

```asm
ldr x3, [x1]          // 读 8 bytes，地址来自 x1
str x3, [x1, #8]      // 写 8 bytes，地址来自 x1 + 8
```

执行单元产生 effective address 后，翻译还需要当前 EL、读/写/取指类型、访问大小、
地址空间标识与控制状态。对于本文的 EL1&0 Stage 1 regime：

- VA 落在 TTBR0 管理的低地址区域还是 TTBR1 管理的高地址区域？
- 这是 EL0 访问还是 EL1 访问？页面允许哪一种权限？
- 地址是否合法，有无对齐要求，目标是 Normal memory 还是 Device memory？
- 若是取指，是否受到 UXN/PXN/WXN 限制？

成功时得到 PA、有效访问权限和 memory attributes；失败时产生同步异常。
因此 MMU 是“地址翻译加访问控制”，不是单纯的 `PA = VA + offset` 加法器。

普通 EL1 `ldr/str` 在 Stage 1 开启后提交 VA。把一个 PA 数值写进 x1，并不能让
`ldr [x1]` 绕过 MMU：它仍被当成 VA。如果恰好有恒等映射，结果才是同数值的 PA。
`LDTR/STTR` 改变的是非特权访问检查语义，也不是 physical load/store 指令。

恒等映射（identity mapping）的重要性主要出现在开启或暂时切换 MMU 的边界：
在 `SCTLR_EL1.M` 从 0 变成 1 后，CPU 立刻会把下一次取指和数据访问当作 VA
翻译。若当前 PC、栈、页表构建代码或必要数据在新页表中没有保持可访问，切换
本身就会立刻触发 instruction/data abort，系统甚至没有机会执行修复代码。把
这些过渡所需的区域暂时建立成 `VA == PA`，可以让开启 MMU 前后的数值地址继续
指向同一物理位置，安全完成 `TTBR/TCR/SCTLR` 配置，再跳到正式的高地址映射。
它只是普通页表中的一种映射，不是绕过 MMU，也不意味着整个地址空间都恒等映射；
过渡结束后可以撤销，或者仅在 suspend/resume 等受控切换场景临时安装。

这句话的边界是“当前指令适用的翻译 regime”：EL2/EL3 有自己的控制寄存器，
Stage 1 关闭但 Stage 2 开启时也不能简单认为地址已是最终 PA。
本文 mini-virt 的普通 Linux EL1 访存没有再启用一层 guest Stage 2。

### 1.2 TLB miss 不是异常，更不是 Linux 缺页

```text
VA + access type + current context
    |
    v
查 TLB ---- 命中且权限允许 ----> PA + attributes -> cache / interconnect
    |
   miss
    v
硬件 page table walker (PTW)
    |
    +-- 描述符有效，权限允许 --> 缓存翻译 --> 完成原访问
    |
    +-- invalid / AF / permission / address-size ... --> 同步 Abort
                                                        |
                                                        v
                                                 OS 异常处理
```

TLB miss 时，只要页表完整且权限满足，CPU 自己走表，Linux 不需要执行代码。
只有翻译或权限等检查失败，才进入 OS；OS 可能建立页面、处理 COW，也可能认定
访问非法。一次写只读页可以在 TLB 已命中时直接发生 permission fault。

### 1.3 硬件内部怎样实现

体系结构规定可观察的翻译和异常语义，不规定某个 TLB 必须几路、多少 entry。
通常实现会有较小的 instruction/data micro-TLB、更大的共享翻译缓存，以及缓存
中间层描述符的 walk cache。TLB 可以用组相联 SRAM 配合 tag 比较器实现；比较的
逻辑身份包含虚页、翻译上下文、ASID，以及需要时的 VMID、安全状态和页大小。

TLB entry 保存的是“翻译后的结果”：输出页基址、页大小、有效权限和属性。
命中时把 VA 的页内 offset 与输出页基址合并，并用当前访问类型检查缓存权限。
block mapping 覆盖更多低位 offset，不必每 4 KiB 重做一次硬件 walk。

PTW 是一个执行依赖内存读的状态机：读上级描述符后才知道下一级表在哪里。
描述符访问可以命中 cache/walk cache，所以“四级页表”不等于“必然四次 DDR
访问”。TLB lookup、cache lookup 和执行流水线可以部分重叠；具体延迟和并行度
是微体系结构选择。QEMU TCG 不仿真这些时序，也不复现 Cortex-A57 的真实 TLB 容量。

## 2. 软件怎样配置 ARM MMU

### 2.1 系统寄存器与指令接口

页表是 RAM 中的数据，寄存器告诉硬件怎样解释它。下面讨论 Cortex-A57 的基础
AArch64 Stage 1 接口，不把后续 LPA2、权限间接编码等扩展混入基础描述符格式。

| 接口 | 核心作用 | 典型指令 |
| --- | --- | --- |
| `SCTLR_EL1.M` | 开启 EL1&0 Stage 1 翻译 | `mrs x0, sctlr_el1`；修改 M；`msr sctlr_el1, x0` |
| `SCTLR_EL1.C/I` | data/instruction cache 控制，和 M 是不同字段 | 同上 |
| `TTBR0_EL1` | 低 VA 区域根表的物理基址、ASID 等 | `msr ttbr0_el1, x0` |
| `TTBR1_EL1` | 高 VA 区域根表的物理基址、ASID 等 | `msr ttbr1_el1, x1` |
| `TCR_EL1.T0SZ/T1SZ` | 两个 VA 区域大小，通常为 `64 - VA_BITS` | `msr tcr_el1, x2` |
| `TCR_EL1.TG0/TG1` | 两套表的 granule，字段编码并不相同 | 同上 |
| `TCR_EL1.IPS` | 输出物理地址大小 | 同上 |
| `TCR_EL1.SHx/IRGNx/ORGNx` | **读取页表**的共享性、cacheability | 同上 |
| `TCR_EL1.EPDx/A1/TBIx` | 禁止相应 table walk、ASID 来源、地址 tag 处理 | 同上 |
| `MAIR_EL1` | 8 个属性槽，描述 Normal/Device 等内存属性 | `msr mair_el1, x3` |
| `TLBI` | 按 VA、ASID、regime、shareability scope 等失效翻译 | `tlbi vae1is, x0`、`tlbi vmalle1is` |
| `AT` + `PAR_EL1` | 请求一次地址翻译并读出结果/失败信息 | `at s1e1r, x0`；`isb`；`mrs x1, par_el1` |
| `ESR_EL1/FAR_EL1/ELR_EL1` | 异常原因、fault VA、异常返回位置 | `mrs x0, esr_el1` 等 |

`AT` 不是一次普通 load，不返回目标内存的内容；它用于查询翻译。
`TTBR` 保存的是表的 PA（有 Stage 2 时，Stage 1 根表地址是相应 IPA），不是任意
C 指针。设置 TTBR 也不是把整个页表“复制进 MMU”，硬件会按需读取描述符。

对常用的 48-bit VA 配置，可以把 TTBR0 区域理解为低端 canonical VA、TTBR1 区域
理解为高端 canonical VA。但精确选择和合法性由 TCR 配置、地址宽度和 TBI 等共同
决定，不能仅凭“寄存器是 64 位，所以所有 64-bit 数值都是有效 VA”。

### 2.2 写 PTE 和刷新 TLB 是两个动作

页表内存更新不自动撤销已经缓存的旧翻译。一个典型的失效顺序示意为：

```asm
str  xNewPte, [xPteVA]    // 更新 RAM 中的 descriptor
 dsb ishst                // 先让表写入在要求的共享域可见
 tlbi vae1is, xOperand    // operand 按指令规定编码 VA/ASID，不是裸指针
 dsb ish                  // 等待失效完成
 isb                      // 让本 PE 后续执行使用同步后的上下文
```

上面只说明顺序，不能当作所有映射变更都适用的通用替换函数。需要
break-before-make 的变更，必须先写 invalid、完成屏障与失效，再安装新描述符。
多核还要选择合适的广播范围。Linux 对这些细节的封装见
[`tlbflush.h`](../linux/arch/arm64/include/asm/tlbflush.h)。

ASID 让不同进程相同 VA 的非 global 翻译共存，避免每次换进程都清空所有硬件 TLB。
`nG=0` 的 global mapping 不按普通非 global ASID 方式区分。ASID 重用也需要正确
的生命周期和失效协议。稍后会看到，QEMU 的 `mmu_idx` **不是 ASID**。

## 3. 用一个实际页表走通 PTW

### 3.1 4 KiB granule 的基础格式

一张 4 KiB 表有 512 个 8-byte descriptor，每级索引 9 bit。48-bit VA 的基础
四级翻译如下；更窄 VA 可以从较低层级开始。

这里的 `entry` 在内存中统一是一个 64-bit（`u64`）descriptor，占 8 字节；
它不是一个只保存地址的 C 指针。一张 4 KiB 页表因此包含 `4096 / 8 = 512`
个 entry，虚拟地址在该级使用 9 bit 选择其中一个 entry。不同级别的 entry
虽然大小相同，但含义不同：中间级通常是指向下一级页表的 `table descriptor`，
允许 block 的 L1/L2 也可以是直接描述大块内存的 `block descriptor`，最后一级
L3 的有效 entry 则是指向 4 KiB 物理页的 `page descriptor`（通常也称 PTE）。

```text
L0/L1/L2 entry = table descriptor -> 下一张页表
                 或 block descriptor -> 直接得到大块 PA
L3 entry       = page descriptor  -> 得到 4 KiB 页的 PA
```

因此“`L3 table`”仍然是一张由 512 个 `u64` entry 组成的表；只是从其中选出的
最后一个 entry 不再指向下一张表，而是包含最终页基址和属性。descriptor 中除了
地址字段，还编码 valid/type、权限、内存属性、Access Flag、执行限制等信息。

其中“内存属性”决定 CPU 应该怎样访问目标区域。最重要的分类是 `Normal memory`
和 `Device memory`：Linux 的 RAM、代码、堆和页表通常是 Normal memory，可以使用
cache，并允许体系结构规定范围内的合并、重排和推测访问；UART、GIC、Timer、SMMU
和 SEC 等 MMIO 通常是 Device memory，不能按普通 RAM 缓存或推测访问，访问顺序和
副作用必须保留。Device memory 还可以细分为 `nGnRnE`、`nGnRE`、`nGRE`、`GRE`，
分别描述是否允许 gathering、reordering 和 early write acknowledgement。

页表 descriptor 通常只保存 `AttrIndx`，它索引 `MAIR_EL1` 中的 8-bit 属性槽，
由 MAIR 槽具体给出 Normal 的 write-back/write-through、read/write-allocate，或
Device 的访问类型。descriptor 的 `SH` 字段另行表示目标区域是 non-shareable、
inner-shareable 还是 outer-shareable；它描述最终映射的内存，不是读取页表本身的
属性，后者由 `TCR_EL1` 的 `IRGN/ORGN/SH` 字段控制。

这些属性与 `AP` 权限、`PXN/UXN` 执行限制、`AF` 访问标志是不同维度：可写不等于
可缓存，可执行也不等于可写。它们最终还会影响 QEMU 的路径选择。映射到 RAM 的
Normal memory 可以在 `tlb_set_page_full()` 中计算 `addend`，由 TCG fast path
直接访问 QEMU 的 host RAM；映射到 Device memory 的 MMIO 不能把 `addend` 当作普通
指针，必须设置 slow-path 标志并调用对应 `MemoryRegionOps` 的设备读写回调。

```text
VA[47:39]     VA[38:30]      VA[29:21]      VA[20:12]       VA[11:0]
 L0 index      L1 index       L2 index       L3 index       page offset
    |              |              |              |
TTBR -> L0 table -> L1 table -> L2 table -> L3 table -> 4 KiB page
                    |              |
                    +-> 1 GiB block+-> 2 MiB block
```

descriptor 类型由 level 和最低两位共同决定：invalid 的 bit 0 为 0；中间级
`0b11` 通常指向下一级表；允许 block 的 L1/L2 上 `0b01` 直接给出输出 block；
L3 的 `0b11` 是 page。不能把每个有效 descriptor 都当作“下一张页表的地址”。

在这里的基础 48-bit 输出地址格式下，table/page 基址取 `[47:12]`；L2 block
取 `[47:21]`，L1 block 取 `[47:30]`，剩余低位从 VA 补入。table descriptor
还可以携带 NSTable、APTable、UXNTable/PXNTable 等层级约束：它不是一个只含
裸地址的指针。更大 PA 的扩展会改变地址字段编码，不能直接沿用这组位范围。

### 3.2 页表 entry 数量与实际内存开销

先看最容易计算的单级平坦页表。设虚拟地址有效位宽为 `V` bit，最小页大小为
`2^P` bytes（也就是页内偏移占 `P` bit），则理论上的虚拟页数量是：

```text
虚拟页数量 = 2^V / 2^P = 2^(V-P)
```

如果每个最终 page entry 是 8 字节，平坦页表本身需要：

```text
页表大小 = 2^(V-P) × 8 = 2^(V-P+3) bytes
```

例如 48-bit VA、4 KiB（`P=12`）页：

```text
理论虚拟页数量 = 2^48 / 2^12 = 2^36
平坦页表大小   = 2^36 × 8 = 2^39 bytes = 512 GiB
```

这个 512 GiB 只是“整个 48-bit 地址空间全部按 4 KiB 页建立一张平坦页表”的
理论结果，不是 Linux 为每个进程实际分配的大小。进程通常只使用地址空间的一小
部分，多级页表会按需分配下级表：没有映射的上级 entry 保持 invalid，对应的
下级页表甚至不存在。

因此实际页表开销要拆成三部分理解：

```text
理论最大 leaf 数量：VA 空间 / 最小页大小
实际 leaf 数量：   已映射范围按 page 或 block 切分后的数量
页表总开销：       L0/L1/L2/L3 等所有已分配页表页的 entry 空间之和
```

连续区域还可以在较高层级使用 block descriptor，进一步减少 leaf entry：

```text
2 MiB 区域使用 L2 block：1 个 entry
2 MiB 区域拆成 4 KiB page：2 MiB / 4 KiB = 512 个 L3 entry
```

没有使用的 VA 区域不需要为每个虚拟页预留 PTE；代码、堆、栈、共享库等实际
映射才会消耗对应的页表结构。多个进程通常各有自己的用户页表，但每个进程仍
只为自己的有效映射分配页表；内核映射通常通过 `TTBR1_EL1` 共享，进程切换时
主要切换 `TTBR0_EL1`。页表页本身和物理数据页也是两种不同开销，不能把“没有
分配物理页”误认为“没有页表项”：延迟分配、文件映射和 copy-on-write 都可能
先建立或共享页表结构，再在缺页时准备具体物理页。

基础 Stage 1 block/page descriptor 的重点：

| 字段 | 含义 |
| --- | --- |
| 输出地址字段 | PA 页/block 基址；低位范围取决于映射大小 |
| `AttrIndx[4:2]` | 选择 `MAIR_EL1` 的属性槽 |
| `AP[7:6]` | EL0 是否可访问、是否只读 |
| `SH[9:8]` | 目标内存共享性；与 TCR 的页表访问属性不同 |
| `AF[10]` | Access Flag；不满足硬件更新条件时 AF=0 会 fault |
| `nG[11]` | 是否为 non-global mapping |
| `PXN[53] / UXN[54]` | 阻止 privileged/unprivileged 执行 |
| `Contiguous[52]` | 一组相邻同属性映射的提示，有成组约束 |

AP 两位的基础含义：

| `AP[2:1]`，即 descriptor `[7:6]` | EL1 数据访问 | EL0 数据访问 |
| --- | --- | --- |
| `00` | RW | 禁止 |
| `01` | RW | RW |
| `10` | RO | 禁止 |
| `11` | RO | RO |

这不是全部有效权限：上级 table descriptor 的 APTable/PXNTable/UXNTable，
SCTLR.WXN、实现支持时的 PAN 等还会进一步约束访问。AF、权限、地址宽度、
内存类型与对齐是不同检查；失败原因也不同。

本实验 Cortex-A57 不应被假定具有后续架构的硬件 AF/dirty 更新扩展。微测直接
设置 AF=1。QEMU 的通用 walker 也实现其他 CPU 的 HA/HD/DBM 逻辑，但那不表示
这些分支会在 A57 上启用。

### 3.3 微测中的两个 VA 映射同一个 PA

配套 [`probe.S`](mmu/probe.S) 设置 `T0SZ=25`，即 39-bit 低 VA；4 KiB granule，
从 L1 开始。`TCR_EL1=0x200803519`，其中 EPD1=1、IPS=40 bit、TTBR0 的表访问
为 inner-shareable、inner/outer write-back。`MAIR_EL1[7:0]=0xff` 表示本实验
使用的 Normal WB 属性。

```text
TTBR0 = 0x40082000

L1[1] @ 0x40082008 -> code_l2 = 0x40083000
  L2[0] -> VA 0x40000000 -> PA 0x40000000，2 MiB 恒等映射

L1[2] @ 0x40082010 -> data_l2 = 0x40084000
  L2[0] -> VA 0x80000000 -> PA 0x41000000，2 MiB，EL1 RW，XN
  L2[1] -> VA 0x80200000 -> PA 0x41000000，2 MiB，EL1 RO，XN
```

对 `VA=0x80000000`：

```text
L1 index = (VA >> 30) & 511 = 2
读 PA 0x40082000 + 2*8 = 0x40082010
  descriptor = 0x0000000040084003       -> 下一张表 PA 0x40084000

L2 index = (VA >> 21) & 511 = 0
读 PA 0x40084000 + 0*8 = 0x40084000
  descriptor = 0x0060000041000701       -> 2 MiB block

PA = 0x41000000 | (VA & 0x1fffff) = 0x41000000
```

这里 `0x701` 包含 valid block、AF=1、SH=inner-shareable、AP=00、AttrIndx=0；
高位 `0x0060000000000000` 设置 PXN/UXN。只读别名把低位改为 `0x781`，即 AP=10。
对 `0x80001238`，相同 block 输出 `0x41001238`，页内 offset 保持不变。

PTW 不要求“页表自身有 VA==PA 映射”才能工作：硬件按照 TTBR 和描述符中的物理
地址访问页表。OS 要修改页表时，才需要通过自己的有效 VA 映射访问这些物理页。
否则把 walk 本身递归地套进同一个 Stage 1，会永远走不完。

这里的关键结论是：**PTW 使用的入口是 `TTBR/table PA`，不是 CPU 当前执行的
VA。** 以 `TTBR0_EL1 = 0x40082000`、当前 VA 的 L0 index 为 2 为例，PTW 直接
计算并读取第一个 descriptor 的内存地址：

```text
L0 descriptor PA = TTBR0_EL1 + L0_index * 8
                 = 0x40082000 + 2 * 8
                 = 0x40082010

descriptor       = 0x0000000040084003
下一张表 PA      = 0x40084000       /* 去掉低位类型/属性位 */
```

之后 PTW 使用下一张表的 PA 加上下一级 index 继续读取 descriptor，直到得到最终
物理页或 block 的 PA。它不是先把 `0x40082010` 当成普通 VA 再经过同一套 Stage 1
翻译；否则会递归依赖正在查询的页表。普通 Linux C 代码访问同一张页表时则不同：
它使用内核 direct map 提供的 VA，经过 CPU MMU 后到达相同的页表 PA。也就是说，
“软件访问页表”和“硬件 PTW 读取页表”共享同一批 DDR 页面，但入口分别是内核 VA
和 `TTBR/table PA`。

因此可以把规则概括为：**页表必须驻留在物理内存中，TTBR 必须指向它的物理地址；
但准备页表的软件代码可以通过 VA 访问这块物理内存。** 例如页表实际位于
`PA=0x40082000`，MMU 开启后 Linux 可以通过 direct map 的某个内核 VA 写入
descriptor，最后仍须把 `0x40082000`（经过架构规定对齐和地址编码）写入
`TTBR0_EL1` 或 `TTBR1_EL1`。在 MMU 尚未开启的早期启动阶段，软件常暂时使用
物理地址数值或恒等映射访问这些页表；这不改变 TTBR 保存页表物理地址的规则。

### 3.4 Linux 管理页表的基本生命周期

Linux 不是为整个虚拟地址空间预先生成一张完整平坦页表，而是把页表作为内核
管理的普通物理页，按映射范围逐级分配和释放。进程的地址空间由 `mm_struct`
描述，根页表通过 `mm->pgd` 指向；内核启动后的全局内核地址空间则由
`init_mm` 和 `swapper_pg_dir` 描述。AArch64 通常把用户空间放在 `TTBR0_EL1`，
内核高地址映射放在 `TTBR1_EL1`，因此切换进程时主要更换用户页表和 ASID，内核
映射可以在进程之间保持共享。

ASID（Address Space ID）的本质是附加在 TLB 翻译上的“这条 VA 映射属于哪个地址
空间”的标签。不同进程可以使用相同的 VA，但由不同页表映射到不同 PA.
在 Linux/AArch64 的实现语境中，可以说“ASID 绑定的是 `mm_struct`”，但准确含义
是：Linux 的 ASID allocator 为一个用户地址空间上下文（`mm_struct`）分配并记录
ASID，切换到该 `mm` 时把对应值装入 `TTBR0_EL1` 的 ASID 字段。硬件只看到
`TTBR0_EL1`、ASID 和页表描述符，并不知道 Linux 的 `mm_struct` 这个 C 结构体。
同一个 `mm_struct` 下的多个线程通常共享 ASID；普通共享内存的两个进程即使映射
了同一个物理页，仍然有不同的 `mm_struct` 和 ASID。ASID 数量有限并会复用，Linux
还要配合 generation 和 TLB invalidation，避免旧地址空间的缓存项被新 `mm` 使用。

因此硬件 TLB 查找的身份不是单独的 `VA page`，而是近似
`(VA page, ASID, 翻译上下文)`。切换到新进程时，Linux 同时选择新的用户页表和
ASID；旧进程的 TLB 项即使暂时留在缓存中，也不会被新进程错误命中。ASID 的价值
是让多个地址空间的翻译缓存可以共存，从而减少每次进程切换时的全量 TLB flush。
ASID 不是物理地址、页表地址、进程 PID，也不是 QEMU TCG 的 `mmu_idx`；后者是
QEMU 用来区分 EL0、EL1、PAN 等访问语义的软件 TLB 模式索引。

可以把一次普通进程切换简化为：

```text
调度器选择 next
  -> switch_mm_irqs_off(prev->active_mm, next->mm)
  -> 根据 ASID/上下文决定是否需要 TLBI
  -> 写入 TTBR0_EL1（用户根页表）
  -> 保留 TTBR1_EL1 的内核根映射
  -> 后续 EL0 VA 使用 next->mm->pgd 进行翻译
```

这里的 `mm->pgd` 是一棵页表树的根，不是所有 PTE 的连续数组。访问一个尚未
建立映射的 VA 时，硬件 walk 可能在某级读到 invalid descriptor，产生 translation
fault；Linux 的异常入口随后调用缺页处理路径。缺页处理可能建立匿名页、装入文件
页、处理 copy-on-write，或者确认访问非法并向进程发送 `SIGSEGV`。页表项和物理
数据页是两种资源：建立 PTE 不一定意味着物理页已经准备好，反之一个物理页也可能
暂时由多个进程通过 COW 共享。

创建进程时，`fork()`/`clone()` 会为新的 `mm_struct` 建立或复制用户页表层级；
可共享的物理页通常先标记为只读，父子进程第一次写入时由 COW 缺页处理分配新页，
更新对应 PTE。内核映射通常不按每个进程重新复制一份物理页，而是让不同用户页表
根中的内核半区指向相同的内核页表结构，具体共享方式还受 KPTI、页表隔离和配置
影响。内核修改共享映射时必须配合页表写入屏障和跨 CPU TLB shootdown。

进程退出时，`do_exit()` 先结束任务本身；如果它是该 `mm_struct` 的最后一个
使用者，引用计数路径最终进入 `mmput()`/`mmdrop()`，释放地址空间。核心过程可以
概括为：

```text
进程退出
  -> 解除或关闭用户 VMA（exit_mmap）
  -> 解除用户 PTE 对物理页的引用，处理 dirty/writeback 等页面生命周期
  -> 释放下级页表页，再释放 PGD 根页
  -> 等待必要的 TLB/RCU 生命周期约束
  -> mm_struct 本身最后释放
```

真正的函数调用会因内核版本、架构和异步回收细节而展开；`exit_mmap()` 负责撤销
用户映射，页表页由架构页表释放函数和 `pgtable` 内存分配器管理，物理页则通过
页引用计数、匿名页/文件页回收机制独立处理。正在其他 CPU 上运行或仍被页表遍历
观察到的旧页表不能立即释放，Linux 必须先完成相应的 TLB 失效、shootdown 和
RCU/延迟释放约束。

因此“进程 kill 后页表什么时候回收”不是收到信号的瞬间简单 `free(mm->pgd)`：
信号终止会先走任务退出和地址空间引用计数；只有最后一个 `mm` 引用消失、用户
映射拆除并满足 TLB/并发访问安全条件后，页表页才会逐级回收。内核全局页表不会
因为某个用户进程退出而回收，它属于整个内核生命周期；临时的 idmap、进程用户页表
和内核共享映射具有不同的所有权。

## 4. QEMU 用哪些结构保存这套状态

### 4.1 先找到真正的 RAM backing

[`mini-virt.c`](../qemu/hw/arm/mini-virt.c) 的 `create_ram()`：

```c
memory_region_init_ram(&vms->ram, NULL, "ram", memmap[VIRT_MEM].size,
                       &error_fatal);
memory_region_add_subregion(sysmem, memmap[VIRT_MEM].base, &vms->ram);
```

第一句创建 RAM `MemoryRegion` 及 backing，第二句把它放进 guest physical
address space 的 `0x40000000`。这些概念不能互换：

```text
MemoryRegion "ram"         guest PA 空间中的一段 RAM 对象
  -> RAMBlock              backing、长度、dirty 等管理信息
      -> host              QEMU 进程可解引用的 host VA

AddressSpace/FlatView      把 guest PA 区间路由到 RAM 或 MMIO MemoryRegion
```

在当前 Linux host 的匿名 RAM 路径中，
[`ram_block_add()`](../qemu/system/physmem.c) 调用 `qemu_anon_ram_alloc()`，
后者在 [`oslib-posix.c`](../qemu/util/oslib-posix.c) 中调用 `qemu_ram_mmap()`。
因此“RAM 就是 QEMU 进程里分配的一块内存”这个理解正确，但本路径具体是
`mmap` backing，不是直接 `g_malloc(4G)`；host 也不必为它分配连续的 4 GiB 物理页。

本次 trace：

```text
qemu_anon_ram_alloc size 4294967296 ptr 0x705627e00000
```

由此，guest PA `0x41000000` 对应的 host VA 为：

```text
0x705627e00000 + (0x41000000 - 0x40000000) = 0x705628e00000
```

### 4.2 CPU 的体系结构状态和软件 TLB 是两组东西

[`CPUARMState`](../qemu/target/arm/cpu.h) 保存 guest 可见的寄存器状态，例如
`cp15.sctlr_el[]`、`ttbr0_el[]`、`ttbr1_el[]`、`tcr_el[]`、`mair_el[]`。
名字中保留 `cp15` 是实现沿革，不表示 AArch64 用 AArch32 CP15 指令访问它们。

`CPUState.neg.tlb` 则是 QEMU 自己维护的每 vCPU 软件缓存：

```text
ARMCPU
  + CPUState
  |   + neg.tlb
  |       + CPUTLBCommon c          flush/lock/统计
  |       + CPUTLBDesc d[mode]      fulltlb、victim entries、large-page 信息
  |       + CPUTLBDescFast f[...]   每个 mode 的 mask/table
  + CPUARMState env
      + cp15                       TTBR/TCR/SCTLR/MAIR ...
      + xregs[]、pc、PSTATE ...
```

这里的 `f` 是 `CPUTLB` 中的 fast descriptor 数组；`f[mode]` 保存该软件 TLB
模式的 `mask` 和 `CPUTLBEntry *table`，供 TCG 生成的 inline fast path 查找
`addr_read`、`addr_write`、`addr_code` 和 `addend`。对应的 `d[mode]` 是完整的
slow descriptor，另外保存 full entry、victim TLB、large-page 和慢路径属性等
信息。因此可以把它们记成：

```text
f[] = 快路径需要的精简索引和 entry table
d[] = 慢路径需要的完整翻译、权限和特殊访问信息
```

[`cpu_tlb_fast()`](../qemu/include/hw/core/cpu.h) 实际取的是
`f[NB_MMU_MODES - 1 - mmu_idx]`，不是直接 `f[mmu_idx]`。`f[]` 的排列和
`CPUState.neg`/`env` 的固定偏移是为了让生成代码能用较短的 host 指令快速取出
`mask`、`table`；这就是后面汇编中 `[rbp-0x60]`、`[rbp-0x58]` 等固定偏移的来源。
这里的“小负偏移”是 QEMU host 数据布局的性能优化，不是 guest 页表地址，也不是
ARM 硬件 TLB 的一部分。

### 4.3 mmu_idx 是什么

**mmu_idx 是 QEMU 为不同访问语义划分软件 TLB 的模式编号。**
同一个 VA，在 EL0、EL1、PAN 生效等条件下可能具有不同权限，不能直接共享未经
区分的缓存 entry。它不是进程号、ASID、TTBR0/TTBR1 的编号，也不是页表层级。

本版本 [`mmuidx.h`](../qemu/target/arm/mmuidx.h) 的部分对应关系：

| ARM 模式 | core mmu_idx | 含义 |
| --- | --- | --- |
| `ARMMMUIdx_E10_0` | 0 | EL1&0 regime 的 EL0 访问 |
| `ARMMMUIdx_E10_1` | 2 | EL1&0 regime 的 EL1 访问 |
| `ARMMMUIdx_E10_1_PAN` | 3 | 加入 PAN 限制的 EL1 模式 |
| `ARMMMUIdx_E2` | 10 | EL2 regime |
| `ARMMMUIdx_Phys_NS` | 19 | Non-secure physical 视图，供 PTW 等内部用途 |

完整 `ARMMMUIdx` 包含 profile 类型位；`arm_to_core_mmu_idx()` 取低 5 bit。
例如本实验普通访问的完整值是 `0x22`，TCG IR 中的 core index 是 `2`。
walker 内部还会切到不对应独立 TLB 的 `Stage1_E1`（`0x41`）；不能把 GDB 中
所有 `ARMMMUIdx` 数字都直接当作 `f[]` 下标。

模式进入 TB flags/翻译上下文，在生成该访存 IR 时已确定，所以 fast path 不需要
每次读取 PSTATE 后再计算数组编号。改变影响翻译的 CPU 状态时必须在适当边界
重建翻译上下文，不能无条件继续使用旧模式生成的代码。

QEMU 的这个 TLB entry 没有完整硬件 ASID tag。实现通过模式划分加失效维护正确性。
例如 [`vmsa_ttbr_write()`](../qemu/target/arm/helper.c) 在 ASID 变化时 flush；
同 ASID 只换根表地址不自动等同于一个新的缓存 namespace，guest 仍需遵守正确的
TLBI 协议。`vmsa_tcr_el12_write()`、`sctlr_write()` 等也处理相关失效。

guest 的 `MSR` 通过 ARM 系统寄存器解码和 `ARMCPRegInfo` 找到相应 write callback，
例如 `helper_set_cp_reg64 -> sctlr_write`；它修改的是 `CPUARMState`。amd64
host 不存在可直接替代 `SCTLR_EL1` 的寄存器写。第 12 节的 GDB 栈展示了这条路径。

## 5. 软件 TLB entry：为什么一次比较能检查权限

### 5.1 fast entry 只有 32 bytes

[`tlb-common.h`](../qemu/include/exec/tlb-common.h) 的主体结构：

```c
typedef union CPUTLBEntry {
    struct {
        uintptr_t addr_read;
        uintptr_t addr_write;
        uintptr_t addr_code;
        uintptr_t addend;
    };
    /* 另有用于索引访问的 union 成员 */
} CPUTLBEntry;

typedef struct CPUTLBDescFast {
    uintptr_t mask;           /* (n_entries - 1) << CPU_TLB_ENTRY_BITS */
    CPUTLBEntry *table;
} CPUTLBDescFast;
```

amd64 上字段 offset 分别为 `0/8/16/24`，entry 大小为 `2^5=32 bytes`。
`addr_read/write/code` 是三个带 flag 的虚页比较值，不是三个 PA。
同一个映射分别记录“能否直接读”“能否直接写”“能否取指”。

`CPUTLBEntryFull` 在 [`cpu.h`](../qemu/include/hw/core/cpu.h) 中保存较冷的详情：

| 字段 | 用途 |
| --- | --- |
| `phys_addr` | 对应 guest PA 页基址 |
| `prot` | `PAGE_READ/WRITE/EXEC` 等有效权限 |
| `lg_page_size` | guest 翻译映射大小的 log2，用于大页相关维护 |
| `attrs` | transaction 的安全空间、user 等属性 |
| `xlat_section` | 慢路径定位 RAM/MemoryRegion section 的编码偏移 |
| `slow_flags[access_type]` | MMIO、watchpoint、byte swap 等处理条件 |
| `extra.arm` | ARM memory attributes、shareability 等缓存信息 |

full entry 与 fast entry 按同一 slot 对应。热点汇编不需要装载整个 full entry。

### 5.2 权限是在 fill 时预先折叠的

[`tlb_set_compare()`](../qemu/accel/tcg/cputlb.c) 的核心逻辑可概括为：

```c
if (!enable) {
    tag = -1;                    /* 该访问类型无权限 */
} else {
    tag = virtual_page | fast_flags;
    if (slow_flags) {
        tag |= TLB_FORCE_SLOW;
    }
}
```

实际调用用 `prot & PAGE_READ`、`prot & PAGE_WRITE`、`prot & PAGE_EXEC`
分别设置三个比较值。因此一个 RW、不可执行的普通 RAM 页可能是：

```text
addr_read  = VA_page
addr_write = VA_page
addr_code  = -1
addend     = host_page - VA_page
```

RO 页则是 `addr_read=VA_page`、`addr_write=-1`。一次读命中后，写仍要比较
`addr_write`，不能借用读权限直接写 RAM。

本版本 [`tlb-flags.h`](../qemu/include/exec/tlb-flags.h) 的 fast flags：

| tag 中的 bit | 含义 |
| --- | --- |
| bit 6 `TLB_INVALID_MASK` | 必须再次检查，不允许普通直接命中 |
| bit 7 `TLB_NOTDIRTY` | 写需要先处理 QEMU 的 clean/dirty 或代码页跟踪 |
| bit 8 `TLB_FORCE_SLOW` | 进入慢路径读取 full entry 的 slow flags |

MMIO 在本版本主要通过 `slow_flags[]` 配合 `TLB_FORCE_SLOW` 编码，不能直接套用
旧版文章里“TLB_MMIO 固定占 fast tag 某 bit”的结构。

正常的比较地址把这些位清零：只要 tag 含 flag，就不能相等。**权限不允许、
缓存没命中、命中但需特殊处理，都会转入 slow path；它们不是同一种原因。**
慢路径再区分“补缓存后完成”“调用设备”“触发 guest exception”。

### 5.3 三种 page size，必须分开

本次测量中：

| 层次 | 大小 |
| --- | --- |
| guest 页表 granule | 4 KiB，一张表 512 entries |
| guest 数据映射叶子 | L2 block，2 MiB，`lg_page_size=21` |
| 当前 mini-virt 的 QEMU `TARGET_PAGE_SIZE` | **1 KiB**，`TARGET_PAGE_BITS=10` |

1 KiB 不是 ARM64 硬件页表 granule。这个自定义 machine 没设置
`MachineClass.minimum_page_bits`；`qemu_create_machine()` 在 CPU 创建之前调用
`cpu_exec_init_all()`，其 `finalize_target_page_bits()` 使用 ARM 的 legacy 默认值
10。随后 CPU 建议的 12 不会把已经确定的粒度调大。
源码见 [`vl.c`](../qemu/system/vl.c)、[`page-vary-target.c`](../qemu/page-vary-target.c)、
[`page-vary-common.c`](../qemu/page-vary-common.c) 和
[`cpu-param.h`](../qemu/target/arm/cpu-param.h)。

后面的真实机器码 `shr ...,5` 和 mask `...fc00` 是这个事实的运行证据。
不要把它改写成常见示例的 `shr ...,7`、mask `...f000`。这也是本 machine 的结果，
不能推广到所有 QEMU ARM machine。

`tlb_set_page_full()` 每次只装入一个 `TARGET_PAGE_SIZE` 区域；2 MiB 的大小
另外用于大映射失效跟踪，不会一次预填充 2048 个 1 KiB entry。硬件使用大页能
增加硬件 TLB reach，并不意味着 QEMU 的软件 fast TLB 也按同样比例增加 reach。

## 6. 从 AArch64 指令到 amd64 机器码

### 6.1 翻译一次，执行多次

```text
guest LDR/STR 编码
  -> target/arm/tcg/translate-a64.c：解码、地址计算、MemOp/mmu_idx
  -> tcg_gen_qemu_ld_i64 / tcg_gen_qemu_st_i64
  -> TCG IR 优化、寄存器分配
  -> tcg/i386/tcg-target.c.inc：prepare_host_addr + direct load/store
  -> TB 中的 amd64 机器码
  -> vCPU host thread 多次直接执行这段代码
```

AArch64 frontend 的 `do_gpr_ld_memidx()` 调用：

```c
tcg_gen_qemu_ld_i64(dest, tcg_addr, memidx, memop);
```

本次微测 `-d in_asm,op,out_asm` 的 guest 与 IR 对照：

```asm
400800e8: ldr  x3, [x1]
400800ec: add  x3, x3, #1
400800f0: str  x3, [x1]
400800f4: subs x2, x2, #1
400800f8: b.ne 0x400800e8
```

```text
qemu_ld_i64 x3,loc3,noat+al+tlb+leq,2
add_i64 x3,x3,$0x1
qemu_st_i64 x3,loc6,noat+al+tlb+leq,2
```

`leq` 是 little-endian 64-bit 访问，最后的 `2` 是 core mmu_idx。
`MemOp` 还编码大小、符号扩展、对齐、atomicity 等信息。
[`memopidx.h`](../qemu/include/exec/memopidx.h) 把它与 mmu_idx 打包：

```c
oi = (memop << 5) | mmu_idx;
mmu_idx = oi & 31;
memop = oi >> 5;
```

本次 helper 参数 `oi=0x17c62`，低 5 bit 为 2。它不是 PTE，也不是 PA。

`qemu_ld` 是“按 guest 内存语义访问”；TCG 的普通 `ld` 则可用于读取 `env` 等
QEMU 自己的数据结构。两者在 IR 中不应混淆。

### 6.2 一条 LDR 的完整 fast path 实测

这一段 amd64 汇编不是手写的，而是由
[`qemu/tcg/i386/tcg-target.c.inc`](../qemu/tcg/i386/tcg-target.c.inc) 根据 TCG
的 `qemu_ld/qemu_st` IR 发射出来的。核心入口是 `prepare_host_addr()`；它先生成
TLB lookup，随后 `tcg_out_qemu_ld_direct()` 或 `tcg_out_qemu_st_direct()` 生成
真正的 host load/store。下面保留与当前 SoftMMU fast path 直接相关的代码骨架；
`tcg_out_*` 是后端的机器码发射函数，省略了 label、寄存器宽度和 REX 前缀等编码
细节：

```c
/* prepare_host_addr(): 为一次 guest load/store 生成 host 地址检查 */
int cmp_ofs = is_ld ? offsetof(CPUTLBEntry, addr_read)
                    : offsetof(CPUTLBEntry, addr_write);
unsigned mem_index = get_mmuidx(oi);
int fast_ofs = tlb_mask_table_ofs(s, mem_index);

/* L0 = guest VA，先计算 CPUTLBEntry 的 slot */
tcg_out_mov(s, tlbtype, TCG_REG_L0, addr);
tcg_out_shifti(s, SHIFT_SHR, TCG_REG_L0,
               TARGET_PAGE_BITS - CPU_TLB_ENTRY_BITS);
tcg_out_modrm_offset(s, OPC_AND_GvEv, TCG_REG_L0, TCG_AREG0,
                     fast_ofs + offsetof(CPUTLBDescFast, mask));
tcg_out_modrm_offset(s, OPC_ADD_GvEv, TCG_REG_L0, TCG_AREG0,
                     fast_ofs + offsetof(CPUTLBDescFast, table));

/* L1 = 本次访问的最后一个字节，检查是否跨 TARGET_PAGE */
tcg_out_modrm_offset(s, OPC_LEA, TCG_REG_L1, addr, s_mask - a_mask);
tcg_out_modrm(s, OPC_AND_GvEv, TCG_REG_L1, TARGET_PAGE_MASK | a_mask);

/* 比较 addr_read 或 addr_write；不相等就跳 slow path */
tcg_out_modrm_offset(s, OPC_CMP_GvEv, TCG_REG_L1, TCG_REG_L0, cmp_ofs);
tcg_out_jcc(s, JCC_JNE, slow_path);

/* 命中：L0 从 entry.addend 读出 VA -> host VA 的偏移 */
tcg_out_ld(s, TCG_TYPE_PTR, TCG_REG_L0, TCG_REG_L0,
           offsetof(CPUTLBEntry, addend));
```

这段代码的关键点是：`cmp_ofs` 根据 load/store 选择 `addr_read` 或
`addr_write`，因此读权限不会自动等价于写权限；`mem_index` 是已编码进 TCG
访存操作的 `mmu_idx`；`TARGET_PAGE_BITS - CPU_TLB_ENTRY_BITS` 把 VA 页号换算
成 entry table 的字节索引。当前 mini-virt 的 QEMU 软件页为 1 KiB、entry 为
32 bytes，所以生成的是 `shr 5`，而不是 ARM 4 KiB 页表常见的 `shr 7`。

命中后，backend 根据 `MemOp` 选择具体的 amd64 指令。64-bit little-endian load
最终会落到 `tcg_out_qemu_ld_direct()` 的这一类发射：

```c
case MO_UQ:
    tcg_out_modrm_sib_offset(s, movop + P_REXW + h.seg,
                             datalo, h.base, h.index, 0, h.ofs);
    break;
```

store 对应 `tcg_out_qemu_st_direct()`：

```c
case MO_64:
    tcg_out_modrm_sib_offset(s, movop + P_REXW + h.seg,
                             datalo, h.base, h.index, 0, h.ofs);
    break;
```

这里的 `h.base` 是 guest VA，`h.ofs` 在 RAM fast path 中为 0，而 `h.index` 保存
从 `entry.addend` 取出的 host 偏移。因此最终形成的寻址形式是：

```text
host address = guest VA + entry.addend
```

如果比较失败，生成的 `jne` 进入 `tcg_out_qemu_ld_slow_path()` 或
`tcg_out_qemu_st_slow_path()`，调用 `helper_ld*_mmu`/`helper_st*_mmu`；如果
命中但 entry 带有 `TLB_FORCE_SLOW`，同样不能直接生成普通 host load/store。

下面是循环 TB 的真实输出，省略机器码字节，保留地址与指令；Intel 语法。
`rbp=env`，`rbx=guest VA`，`rdi/rsi` 是 backend 的临时寄存器，结果放进 r12。
前面的 TB prologue 和 `mov rbx,[rbp+0x48]` 不计入这个访存片段。

```asm
705730001c93: mov rdi, rbx
705730001c96: shr rdi, 0x5
705730001c9a: and rdi, QWORD PTR [rbp-0x60]
705730001c9e: add rdi, QWORD PTR [rbp-0x58]
705730001ca2: lea rsi, [rbx+0x7]
705730001ca6: and rsi, 0xfffffffffffffc00
705730001cad: cmp rsi, QWORD PTR [rdi]
705730001cb0: jne 0x705730001d94
705730001cb6: mov rdi, QWORD PTR [rdi+0x18]
705730001cba: mov r12, QWORD PTR [rbx+rdi]
```

逐条对应 [`prepare_host_addr()`](../qemu/tcg/i386/tcg-target.c.inc)：

1. **算 slot 地址。** slot 是 QEMU 自己的 fast TLB table 中的数组位置，不是
   ARM 页表的 L0/L1/L2/L3 entry。先用 guest VA 的 QEMU 软件页号计算 slot：

   ```text
   software_page = VA >> TARGET_PAGE_BITS
   slot_index    = software_page & (entry_count - 1)
   entry         = table[slot_index]
   ```

   当前 entry 大小为 32 bytes、软件页大小为 1024 bytes，`shr 5` 是
   `TARGET_PAGE_BITS - CPU_TLB_ENTRY_BITS = 10-5`。再与 `mask` 相与，得到已经
   乘过 32 的 slot byte offset；加上 `table` 就得到 `CPUTLBEntry` 地址。
   例如 `VA=0x80000000` 在当前 256-entry table 中得到 `slot_index=0`，首先检查
   `table[0]`，随后仍必须比较 entry 中的 `addr_read/write/code`，因为不同 VA
   可能冲突到同一个 slot。冲突时 primary table miss，QEMU 再检查 victim TLB。
2. **算比较值。** 8-byte 访问允许当前条件下的非对齐访问，使用 `VA+7` 的末字节
   所在页参与检查。mask `...fc00` 清除 1 KiB 页内 offset。
3. **比较读 tag。** `[entry+0]` 是 `addr_read`。值不等就跳慢路径。
4. **取偏移并读取。** `[entry+24]` 是 addend；最后一条 amd64 `mov` 用
   `[guest_VA + addend]` 直接读取 QEMU RAM backing。

slot 公式是：

```text
index       = (VA >> TARGET_PAGE_BITS) & (n_entries - 1)
entry_addr  = table + index * 32

等价的机器码写法：
byte_offset = (VA >> (TARGET_PAGE_BITS - 5)) & ((n_entries - 1) << 5)
```

`mask=0x1fe0` 对应当前 256 entries；这是可动态调整的软件表，并非 A57 硬件参数。
从 `mov rdi,rbx` 到真正访存一共 **10 条 amd64 指令**，其中一个条件分支。
所以“检查后直接访问”是对的，但不能说整条 guest load 只需一条 host load：
它还读了 mask、table、tag、addend，另有 TB 管理、寄存器搬运等外围开销。
这里没有测量周期，不能把 10 条指令直接换算成固定耗时。

### 6.3 为什么 `VA+7` 能发现跨页

slot 按访问起始地址选择，比较值按末字节计算。如果 8 bytes 跨过软件页边界，
末字节页号不同于 entry 的起始页号，比较必然失败。慢路径分别检查两边的映射、
权限和内存属性，不能假设两个 guest 相邻页在 host backing 中也相邻。

backend 根据 `atom_and_align_for_opc()` 的结果决定 mask 和地址调整。如果要求
的对齐已不小于访问大小，直接 mask 起始地址并保留需检查的对齐低位即可；
不能把这个 `+7` 模板推广到所有大小、所有对齐要求和所有 atomic 操作。

### 6.4 STR 的变化只是比较写 tag，然后做写入

同一个 TB 的 store 核心输出：

```asm
705730001cc5: mov rdi, rbx
705730001cc8: shr rdi, 0x5
705730001ccc: and rdi, QWORD PTR [rbp-0x60]
705730001cd0: add rdi, QWORD PTR [rbp-0x58]
705730001cd4: lea rsi, [rbx+0x7]
705730001cd8: and rsi, 0xfffffffffffffc00
705730001cdf: cmp rsi, QWORD PTR [rdi+0x8]
705730001ce3: jne 0x705730001db4
705730001ce9: mov rdi, QWORD PTR [rdi+0x18]
705730001ced: mov QWORD PTR [rbx+rdi], r12
```

`[rdi+8]` 是 `addr_write`。它已经代表该 EL/mmu_idx 下可直接写这个页：
权限检查没有消失，而是大部分复杂工作在 fill 时完成，再用一次等值比较确认
“当前地址仍然匹配那份获准直接写的缓存结果”。

### 6.5 addend 的真实数值闭环

同一次运行的 GDB fill 结果：

```text
VA=0x80000000
phys_addr=0x41000000, prot=0x3, lg_page_size=0x15
mask=0x1fe0
addr_read =0x80000000
addr_write=0x80000000
addr_code =0xffffffffffffffff
addend    =0x7055a8e00000
```

[`tlb_set_page_full()`](../qemu/accel/tcg/cputlb.c) 的关键原代码是：

```c
addend = (uintptr_t)memory_region_get_ram_ptr(section->mr) + xlat;
/* ... */
tn.addend = addend - addr_page;
```

这里中间变量 `addend` 最初是 host 页地址，写进 entry 时才减去 guest VA 页基址。
本次数据为：

```text
RAM host base                 = 0x705627e00000
PA 在该 RAM MemoryRegion 偏移 = 0x01000000
host page                     = 0x705628e00000
VA page                       = 0x000080000000
entry.addend                  = 0x7055a8e00000

VA + entry.addend             = 0x705628e00000
```

只读别名 `VA=0x80200000` 的 addend 是 `0x7055a8c00000`；两者相加得到同一个
host 地址。**addend 是每个缓存映射的偏移，不是整台 VM 通用的 RAM base。**
它能为不连续 guest VA、不同 PA、RAM aliases 提供各自正确的直接访问地址。

最终 `mov [rbx+rdi]` 仍受 host 进程地址空间保护。host 可能命中自己的 TLB/cache，
也可能发生 host page fault；这与 guest ARM TLB miss/Abort 是两套独立机制。
所谓“直接访问 DDR”在这里准确地说是“直接读写表示 guest RAM 的 host backing”。

## 7. 慢路径：从 generated stub 回到 C，再回到机器码

### 7.1 JNE 的目标也是 TCG 生成的代码

上面 load 的慢路径目标 `0x705730001d94`：

```asm
mov rsi, rbx                 // 第二参数：guest VA
mov rdi, rbp                 // 第一参数：env
mov edx, 0x17c62             // 第三参数：MemOpIdx
lea rcx, [rip-0xe8]          // 本次实际指向 0x705730001cbe，恢复位置
call QWORD PTR [rip+0x34]    // helper_ldq_mmu
mov r12, rax                 // helper 已经完成 load，取返回值
jmp 0x705730001cbe           // 继续执行 guest ADD
```

这里 `lea` 的精确位移以反汇编原日志为准；核心是传入 JIT 内的恢复地址。
实现见 `tcg_out_qemu_ld_slow_path()`；store stub 多传一个待写值，并在 helper
完成 store 后跳到后续 guest 指令。**不是 helper 只填 TLB，返回后再执行一次
原来的 host load/store**，否则 MMIO 等有副作用的访问就可能被重复执行。

retaddr 还用于 fault 时恢复对应 guest PC/指令状态。JIT 中不必在每条 guest
指令前都把精确 PC 写回 `env`，但异常必须能恢复到正确的 faulting instruction。

### 7.2 GDB 的真实调用栈

第一次读 `0x80000000`，在 `arm_cpu_tlb_fill_align` 抓到的栈，省略参数地址：

```text
#0  arm_cpu_tlb_fill_align(address=2147483648, access_type=MMU_DATA_LOAD, mmu_idx=2, size=8)
#1  tlb_fill_align                         accel/tcg/cputlb.c:1245
#2  mmu_lookup1                            accel/tcg/cputlb.c:1656
#3  mmu_lookup                             accel/tcg/cputlb.c:1748
#4  do_ld8_mmu                             accel/tcg/cputlb.c:2385
#5  helper_ldq_mmu                         accel/tcg/ldst_common.c.inc:40
#6  code_gen_buffer ()
```

`code_gen_buffer` 就是生成的 amd64 指令所在区域。它调用 C helper，C helper
解析缓存和 ARM 状态，成功后回到上节 stub。正常 fast hit 没有这条 C 调用栈。

因此日志中出现 `helper_ldq_mmu`，只能说明这次访问离开了 inline fast path；
它还不能说明发生了 ARM page-table walk。helper 内部先检查 QEMU 的 victim TLB，
只有 victim 也未命中时，才会继续调用 `tlb_fill_align()` 和 ARM walker。

### 7.3 generic slow path 先做什么

[`mmu_lookup1()`](../qemu/accel/tcg/cputlb.c) 并非一进入就 PTW：

```text
查对应访问类型的 fast entry
  |
  +-- 对应页仍在，只是 flag 要特殊处理 -> 读取 full entry、处理 flag
  |
  +-- 页不匹配 -> victim_tlb_hit()
                    |
                    +-- 命中 -> 把 victim 与 primary slot 交换
                    |
                    +-- 未命中 -> tlb_fill_align()
                                   -> CPU target 的 tlb_fill_align callback
                                   -> 成功后 tlb_set_page_full()
```

victim TLB 保存被 primary table 冲突挤出的 entry；它用 C 代码查找，不属于上节
那段十条指令的快路径。主表是直接映射，虚页索引冲突并不代表 ARM 页表发生改变。

可以把三种结果具体区分为：

```text
primary hit
  -> 生成的 amd64 inline lookup 命中
  -> 直接使用 entry.addend 访问 host backing

victim hit
  -> primary slot 没命中，进入 helper
  -> victim_tlb_hit() 找到被挤出的 entry
  -> 与 primary entry 交换，再完成本次访问
  -> 不重新读取 ARM 页表

primary miss + victim miss
  -> tlb_fill_align()
  -> arm_cpu_tlb_fill_align()
  -> get_phys_addr() / PTW 读取 TTBR 和 guest descriptor
  -> tlb_set_page_full() 重新生成 entry
```

所以 `victim hit` 不是 ARM 硬件 TLB 命中，也不是一次新的 PTW；它是 QEMU 自己
为 direct-mapped 软件 TLB 增加的第二级缓存命中。victim entry 之所以存在，
是因为不同 guest 页经过软件 slot 索引后发生冲突；这不表示 guest 页表内容改变。
交换回 primary 后，后续相同访问通常又能回到 inline fast path。

fill 可能 resize table，所以源码特别要求 fill 后重新取 index/entry，不能继续
使用调用前的指针。慢路径随后还会检查对齐、跨页、watchpoint、dirty、MMIO 等。

## 8. ARM walker 如何用 C 实现硬件 PTW

### 8.1 先选择 regime，再按 descriptor 逐级读取

[`arm_cpu_tlb_fill_align()`](../qemu/target/arm/tcg/tlb_helper.c) 做必要的对齐检查，
然后调用 [`get_phys_addr()`](../qemu/target/arm/ptw.c)：

```text
get_phys_addr
  -> get_phys_addr_gpc
  -> get_phys_addr_nogpc
       -> 判断物理模式、MMU disabled、单阶段/两阶段等
       -> get_phys_addr_lpae        本文 AArch64 页表的主体
```

名字 `lpae` 有历史背景，不表示这里只支持 AArch32。这个函数处理 AArch64 的
long descriptor、不同 granule/level/地址大小等。本文 A57 走基础格式分支。

walker 从 TCR/TTBR 解出起始层、stride、索引 mask、输出地址宽度等。核心循环
在 `next_level:` 附近，抽取后的原代码：

```c
descaddr |= (address >> (stride * (4 - level))) & indexmask;
descaddr &= ~7ULL;
if (!S1_ptw_translate(env, ptw, descaddr, fi)) {
    goto do_fault;
}
descriptor = arm_ldq_ptw(env, ptw, fi);
/* 验证 valid/type/输出地址大小 */
if ((descriptor & 2) && (level < 3)) {
    tableattrs |= extract64(descriptor, 59, 5);
    level++;
    indexmask = indexmask_grainsize;
    goto next_level;
}
```

`stride=9` 时，L1 从 VA `[38:30]` 取索引，L2 从 `[29:21]` 取索引。
公式多出的 3 bit 来自每个 descriptor 占 8 bytes。
叶子分支按 level 算 block/page 大小，再合并 offset：

```c
page_size = 1ULL << ((stride * (4 - level)) + 3);
descaddr &= ~(hwaddr)(page_size - 1);
descaddr |= address & (page_size - 1);
```

随后处理 AF/支持时的 dirty 更新，合并上层权限，调用 `get_S1prot()` 计算当前
访问模式的有效 `PAGE_READ/WRITE/EXEC`，用 AttrIndx 查 MAIR，保存内存属性。
如果 `ptw->in_prot_check & ~prot` 非零，进入 permission fault。
对允许硬件更新 descriptor 的 CPU，通用代码还使用 `arm_casq_ptw()` 处理原子更新
和并发变化；本次 A57、AF=1 的样例没有走这个分支。

如果 guest MMU 关闭，会走 `get_phys_addr_disabled()` 等相应分支，不读取 Stage 1
页表。但 **guest PA 仍不等于 host pointer**：QEMU 仍须区分 RAM/MMIO、计算
host backing。因此 MMU-off 的普通 guest load/store 也可以使用 SoftMMU 的
tag/addend 缓存；“SoftMMU”并不只服务于 guest 开启 MMU 之后的阶段。

### 8.2 walker 怎样读页表，为什么不会递归走同一张表

`S1_ptw_translate()` 把 descriptor 的地址转换为可读 host 地址：

```c
flags = probe_access_full_mmu(env, addr, 0, MMU_DATA_LOAD,
                              arm_to_core_mmu_idx(s2_mmu_idx),
                              &ptw->out_host, &full);
```

单阶段 Non-secure 情况下，`s2_mmu_idx` 是 `Phys_NS`，它用的是物理地址视图，
不是原来的 EL1 Stage 1 VA 翻译。这条内部 probe 也可以缓存 PA->host 的结果。
若启用 Stage 2，则读取 Stage 1 页表的 IPA 还要经过 Stage 2，这是两阶段 PTW
复杂度增加的来源；本文没有开启这条实验路径。

得到 RAM host 地址后，`arm_ldq_ptw()` 直接读 descriptor：

```c
void *host = ptw->out_host;
if (likely(host)) {
    data = qatomic_read__nocheck((uint64_t *)host);
    data = ptw->out_be ? be64_to_cpu(data) : le64_to_cpu(data);
} else {
    /* 通过 MemoryRegion 路径处理页表位于 MMIO 等情况 */
}
```

GDB 在本次真实 walk 中观察到：

```text
in_mmu_idx=0x41   in_ptw_idx=0x33   in_prot_check=0x1
out_phys=0x40082010 -> descriptor 0x0000000040084003
out_phys=0x40084000 -> descriptor 0x0060000041000701
```

`0x33 = ARM_MMU_IDX_A | 19`，正是 Phys_NS。
只读别名的第二个 descriptor 地址是 `0x40084008`，读到
`0x0060000041000781`。这些数值与第 3 节手算的 PTW 完全对应。

### 8.3 从 ARM 结果填入 generic TLB

这个版本的 callback 成功时把 `res.f` 复制到输出 `CPUTLBEntryFull` 并返回 true；
通用 `tlb_fill_align()` 再调用 `tlb_set_page_full()`。不要照搬旧版本
`arm_cpu_tlb_fill()` 直接安装 entry 的调用顺序。

`tlb_set_page_full()` 的工作按依赖关系是：

1. 对齐 VA/PA，保留 guest 大映射信息。
2. `address_space_translate_for_iotlb()`：从 PA 找到 `MemoryRegionSection`、
   region 内 offset `xlat`，以及 region 对权限的进一步限制。
3. RAM：`memory_region_get_ram_ptr()+xlat` 得到 host 页；MMIO：设置慢路径标志。
4. 合并 readonly、dirty tracking、watchpoint 等条件，生成三个 access tag。
5. 必要时把旧 slot 挤入 victim 表，写入 full entry 和 fast entry。

至此 ARM PTW、有效权限、PA 路由已经被压缩到 tag/addend。后续普通 hit 不再
解析 TTBR/PTE，不再查 FlatView，也不调用 `address_space_read()`。

### 8.4 权限错误如何变成 guest exception

微测在 RO 别名上先成功 load，再执行同地址 store。填表后的 entry 是：

```text
addr_read = 0x80200000
addr_write= 0xffffffffffffffff
addr_code = 0xffffffffffffffff
addend    = 0x7055a8c00000
```

store tag 比较失败；write 类型的 victim lookup 也失败；walker 读到 AP=10，
得到 `prot=PAGE_READ`，发现请求 `PAGE_WRITE` 不满足。

`arm_cpu_tlb_fill_align()` 调用 `cpu_restore_state(cs, ra)`，然后
`arm_deliver_fault()` 构造 syndrome、fault address，并通过 exception 路径退出
当前 JIT 执行。该 store 不写入 backing，也不会作为普通 helper 成功返回。
随后 ARM exception entry 进入 guest `VBAR_EL1 + 0x200` 的 EL1h 同步异常向量。

`-d int` 的实测片段：

```text
Taking exception 4 [Data Abort] on CPU 0
...from EL1 to EL1
...with ESR 0x25/0x9600004e
...with FAR 0x80200000
```

`ESR=0x9600004e` 中 EC=0x25 表示 same-EL Data Abort，WnR=1 表示写，
DFSC=0x0e 表示 level 2 permission fault。微测 handler 检查完整 ESR 和 FAR，
将 ELR 加 4 跳过这条预期失败的 STR，然后 `eret`。
这是 ARM guest 的异常，不能用“amd64 host 给 QEMU 一个 SIGSEGV”替代解释。

## 9. 哪些访问不能直接使用这十条指令

| 情形 | 为什么需要额外处理 |
| --- | --- |
| primary tag miss | victim lookup 或 ARM translation/fill |
| 对应访问没有权限 | 根据架构重新检查并产生正确 Abort |
| MMIO | 调用设备 `MemoryRegionOps`，不能把寄存器当普通 RAM 指针 |
| `TLB_NOTDIRTY` | 先维护 dirty bitmap、可能的已翻译代码页写保护等 |
| watchpoint | 触发调试语义 |
| 跨软件页/需要特殊对齐 | 两页可能映射、权限、属性不同 |
| byte swap、特殊内存属性 | 使用适合语义的 load/store 或 helper |
| exclusive/atomic、部分向量访存 | 另有原子性、拆分与并发处理路径 |

`TLB_NOTDIRTY` 是 QEMU 内部的写跟踪条件，不是 ARM PTE 的 AF/DBM，也不是
Linux 对文件页定义的 dirty 状态。必要时第一次写处理完可清除标志，后续再直接写。
本次 probe 的 RW 数据 entry 从一开始 `addr_write` 就没有 NOTDIRTY；trace 中没有
该数据地址的 notdirty 事件，不能编造“第一条 store 必然进入 dirty helper”。

TCG 也必须维护 ARM memory ordering：barrier、acquire/release、exclusive 等各有
实现。本文的十条指令只是一次普通 64-bit RAM 访问，不能用它代表所有 ARM
访存指令的完整语义。amd64 较强的内存排序可以减少某些成本，但不代表可以忽略
guest memory model。

软件 TLB 按 vCPU 保存，MTTCG 中不同 vCPU 的翻译缓存是不同对象，RAM backing
却共享。hit 不逐次拿 BQL；跨 CPU 的 TLB invalidation、MemoryRegion 生命周期、
原子操作和写跟踪另有同步协议。不要把“直接解引用 backing”解释成“可以随时
释放或重映射 backing 而无需撤销缓存”。

### 9.1 失效为何是快路径正确性的另一半

仅在 fill 时计算权限，必须搭配正确的失效机制。否则页表改成只读后，旧的
`addr_write=VA_page` 会继续允许直接写。guest 的页表写只是 RAM 写，不能假定
QEMU 会监视每个 PTE 并自动修改所有 vCPU 的软件 TLB。

[`tlb-insns.c`](../qemu/target/arm/tcg/tlb-insns.c) 将 guest TLBI 注册为系统指令
callback，例如：

```text
TLBI VMALLE1IS
  -> tlbi_aa64_vmalle1is_write
  -> 计算 EL1&0 regime 对应的 mmu_idx mask
  -> tlb_flush_by_mmuidx_all_cpus_synced

TLBI VAE1IS
  -> tlbi_aa64_vae1is_write
  -> 从 operand 解出 VA，并计算有效 VA bits
  -> tlb_flush_page_bits_by_mmuidx_all_cpus_synced
```

非广播形式在适用情况下只处理当前 CPU；广播形式通过 CPU 工作/同步机制使相关
vCPU 缓存失效。primary 和 victim 缓存都必须维护，不能仅清除主表而让旧 entry
又从 victim 回来。generic TLB 还记录 large-page 范围，以便 guest 对一个大映射
执行失效时，撤销对应的软件子页缓存。

这个实现可以比硬件更保守地清除缓存。比如 `TLBI_ASIDE1IS` 使用与 VMALLE1IS
相同的 callback；VAE1 系列也不实现只清指定 ASID/只清最后一级的精细区分。
多清缓存影响仿真性能，但不会因此允许过期访问。这再次说明：QEMU 软件 TLB
是在保证架构语义，不是在还原某款芯片的每一次硬件 TLB 命中。

## 10. TLB、TB、取指缓存不是同一件事

数据访存通常在每次执行 guest LDR/STR 时走上述 inline lookup。取指则还经过
TCG 的翻译缓存：翻译 TB 时需要读取 guest 指令页，验证取指权限并取得代码；
生成后，CPU 执行的是 host 指令，不再逐条重新从 guest RAM 取同一条 ARM 指令。

```text
Software TLB：缓存 guest address -> host backing / 特殊访问属性
TB cache：   缓存 guest 指令 -> host 机器码
Host TLB：   amd64 硬件缓存 host VA -> host PA
```

TB lookup/linking、代码页修改后的 invalidation、translation regime 改变等，
共同维护“下一次执行的是正确 guest 指令”这个契约。不能因为 `addr_code` 在
`CPUTLBEntry` 里，就推断每条 guest 指令都执行与 LDR 相同的 inline tag lookup。

本次循环的一个细节正好说明这种交互：首次进入循环的 TB 包含前面的寄存器初始化，
回跳到 `0x400800e8` 后还需要生成一个从 loop label 开始的 TB。其代码页
`0x40080000` 与数据页 `0x80000000` 在当前 256-entry 主表里都落入 slot 0，
取指缓存填充将数据 entry 挤入 victim 表。之后第一次循环 load 进入 helper，
却能在 victim 找到它，不需要再做 ARM PTW。后面已经生成的循环 TB 重复执行，
该数据访问继续走 fast path。

## 11. 可复现微测、日志和测量边界

### 11.1 为什么用小程序而不是只截 Linux 的海量日志

[`probe.S`](mmu/probe.S) 用带 ARM64 Image header 的小镜像沿用 mini-virt direct
boot，在必要时从 EL2 降到 EL1，设置自己的 TTBR/TCR/MAIR 和异常向量。
它不修改 machine、QEMU、Linux 或正常 initramfs：

1. 代码和页表所在 RAM 保持恒等映射，安全开启 MMU。
2. 对 `VA=0x80000000` 做 4 次 load/add/store，最终值必须为 4。
3. 对同 PA 的 RO 别名读取，值也必须为 4。
4. 写 RO 别名，检查 ESR/FAR；未发生预期异常或数据错误则 FAIL。
5. 使用 semihosting 输出结果并退出。

正常结果：

```text
MMU probe: PASS (4 increments, RO alias, EL1 permission fault)
```

这里 semihosting 只用于报告和退出，不替代被测的 LDR/STR。原始日志和二进制
生成在 `qemu/build/mmu-probe/`，符合本仓库 component build output 的归属约定。

从 repository root 运行：

```sh
./vm/aarch64/mini-virt/build-all.sh
bash docs/mmu/capture.sh
```

工具文件：

- [`probe.S`](mmu/probe.S)、[`probe.ld`](mmu/probe.ld)：实验镜像及固定链接地址。
- [`capture.sh`](mmu/capture.sh)：构建镜像，运行 host GDB，采集日志。
- [`probe.gdb`](mmu/probe.gdb)：条件断点、backtrace、PTW descriptor、fill 和 helper 计数。
- [`decode-log.py`](mmu/decode-log.py)：对 `OBJD-H/OBJD-T` 原始字节调用 binutils 反汇编。

当前 QEMU build 的 `out_asm/in_asm` 输出带 `OBJD-H/OBJD-T` 字节，而不是已格式化
的指令名。脚本保留原始日志，并用 `objdump`/`aarch64-linux-gnu-objdump` 解码，
没有把手写示意汇编冒充运行输出。

| 生成文件 | 内容 |
| --- | --- |
| `combined.log` | `in_asm,out_asm,op,int` 和选择的 trace 原始输出 |
| `decoded.log` | 同地址、同机器码的可读反汇编 |
| `gdb.log` | helper 次数、victim 命中、PTW、entry 和调用栈 |
| `probe.elf/probe.bin` | 带符号 ELF 和 direct-boot 镜像 |

日志选项实际为 `-d in_asm,out_asm,op,int,trace:... -D file`。
`in_asm/out_asm` 是 `-d` 的项目，不是独立的 `-in/-out` 参数。
本次把 trace 与 disassembly 写入同一个日志；避免同时指定不同的 `-trace file`
和 `-D` 后误以为它们必然分离成两份输出。

### 11.2 实测计数支持什么结论

GDB 只对两个被测 VA 统计 `helper_ldq_mmu/helper_stq_mmu`，不把初始化、页表读、
取指或 semihosting 的访存混进去。结果：

```text
HELPER ('helper_ldq_mmu', '0x80000000') count 1
VICTIM LOOKUP page=0x80000000
VICTIM HIT false
ARM FILL address=0x80000000 type=0 idx=2
...
HELPER ('helper_ldq_mmu', '0x80000000') count 2
VICTIM LOOKUP page=0x80000000
VICTIM HIT true
...
HELPER ('helper_ldq_mmu', '0x80200000') count 1
HELPER ('helper_stq_mmu', '0x80200000') count 1
```

| 被测访问 | 执行次数 | helper 次数 | ARM translation callback 次数 |
| --- | --- | --- | --- |
| RW VA load | 4 | 2 | 1 |
| RW VA store | 4 | 0 | 0 |
| RO alias load | 1 | 1 | 1 |
| RO alias store | 1（fault） | 1 | 1（返回异常） |

因此四次 RW store 全部直接命中；四次 RW load 中两次直接命中、一次 cold fill、
一次 victim hit。不能把 helper 总数直接解释为硬件 TLB miss 数，更不能把这个
刻意制造 alias/冲突的小程序的百分比当成 Linux workload 的常见命中率。

这里的“helper 次数”和“PTW 次数”必须分开读：本实验第二次访问
`0x80000000` 进入了 `helper_ldq_mmu`，但日志显示 `VICTIM HIT true`，因此没有
再次出现 `ARM FILL` 或 descriptor 读取。换句话说，helper 是 QEMU 的慢路径入口，
PTW 是慢路径在 victim miss 之后才选择的后续分支。

本实验用“已知执行次数 + helper 入口计数 + PTW 条件断点 + 实际机器码”闭环，
无需额外 TCG plugin。`out_asm` 只证明生成了什么，不能独自证明某分支被执行；
GDB 断点计数补上了这一层证据。若要评估复杂 workload 的性能，应另外区分
inline hit、victim hit、真正 walk、MMIO、dirty、跨页等，并在不挂 GDB 的运行中
计时；GDB 和日志会显著扰动性能。

### 11.3 复现时哪些数值会变化

host RAM、TCG buffer、C 函数和 heap 指针受 ASLR、分配顺序影响，每次可能不同。
应核对的是 `host_page = VA + addend`、tag/权限和调用关系，不是硬匹配某个 host
地址。guest descriptor 地址由本测试 linker layout 固定；若改测试布局，应同步
修改 `probe.gdb` 的条件地址。GDB 的 slot 计算也明确对应当前 1 KiB 软件页粒度，
换 machine 或调整 QEMU page size 时必须重新核对。

## 12. Linux 何时开 MMU，怎样从 PA 平滑切到 VA

### 12.1 当前源码不是“先建好最终所有页表再打开”

核心文件是 [`head.S`](../linux/arch/arm64/kernel/head.S)、
[`proc.S`](../linux/arch/arm64/mm/proc.S)、
[`pi/map_range.c`](../linux/arch/arm64/kernel/pi/map_range.c) 和
[`pi/map_kernel.c`](../linux/arch/arm64/kernel/pi/map_kernel.c)。
这套代码的 boot 主线为：

```text
primary_entry                       MMU-off direct boot
  -> __pi_create_init_idmap         建启动恒等映射
  -> init_kernel_el                 从入口 EL 配置运行环境
  -> __cpu_setup                    MAIR/TCR，准备 SCTLR 值等
  -> __primary_switch
       TTBR0 = init_idmap_pg_dir
       TTBR1 = reserved_pg_dir
       -> __enable_mmu              安装 TTBR，设置 SCTLR.M
       -> 继续通过 idmap 执行        数值还是低地址，但现在是 VA
       -> __pi_early_map_kernel     建高地址内核映射、必要的 relocation
          -> idmap_cpu_replace_ttbr1(init_pg_dir)
          -> 最后换为 swapper_pg_dir
       -> ldr x8, =__primary_switched
       -> br x8                     显式跳转到高 VA
  -> __primary_switched
       -> start_kernel
```

`create_init_idmap()` 的 `map_range()` 将输入和输出都传入同一数值的内核 text/data
范围；这时位置无关的 early 代码运行在物理加载地址，构造的就是 VA==PA 映射。
它不是把所有 64-bit 地址恒等映射。

`__enable_mmu` 的关键源码：

```asm
phys_to_ttbr x2, x2
msr ttbr0_el1, x2
load_ttbr1 x1, x1, x3
set_sctlr_el1 x0
ret
```

所在代码放在 `.idmap.text`，开启 MMU 后下一条取指仍能通过恒等映射找到同一段
物理代码。`set_sctlr_el1` 包含所需同步；切换过程还要保证当时使用的返回地址、
栈和数据可访问。只映射“下一条指令”而忘记栈、页表构建的数据，仍会出错。

`__primary_switch` 随后调用 `__pi_early_map_kernel`。所以这里存在一个很有用的
中间状态：**PC 仍走低地址 idmap，但已经通过 TTBR1 访问高地址数据。**
最后的 `br x8` 才改变控制流使用的地址数值；打开 M 不会自动把 PC 加上 kernel offset。

### 12.2 三个 host GDB 断点看到的切换

[`linux-boot.gdb`](mmu/linux-boot.gdb) 观察 QEMU 的寄存器写和 ARM walker，
本次截取如下：

```text
ENABLE pc=0x403bd3f0
SCTLR(new)=0x200002034f4d91d
TTBR0=0x403f0000  TTBR1=0x403bf000  TCR=0x34b5503510

#0 sctlr_write
#1 helper_set_cp_reg64
#2 code_gen_buffer
#3 cpu_tb_exec

HIGH VA address=0xffff8000801c0000 PC=0x4035f5b0
TTBR0=0x403f0000  TTBR1=0x404cd000  TCR=0x34b5503510
access_type=MMU_DATA_STORE

HIGH PC fetch=0xffff8000801d6638
TTBR0=0x403f0000  TTBR1=0x403c0000  TCR=0x34b5503510
```

`vmlinux` 的符号确认最后地址就是 `__primary_switched`：

```text
ffff800080000000 _text
ffff8000801bd3b8 __enable_mmu
ffff8000801bf000 reserved_pg_dir
ffff8000801c0000 swapper_pg_dir
ffff8000801d6638 __primary_switched
ffff8000801f0000 init_idmap_pg_dir
```

本次 Image 物理起点为 `0x40200000`，因此例如 `init_idmap_pg_dir` 对应
`0x40200000 + 0x1f0000 = 0x403f0000`，与 TTBR0 一致。
高 VA store 时 PC 还是 `0x4035f5b0`，直接证明了上述中间状态。

当前 `.config` 是 `CONFIG_ARM64_4K_PAGES=y`、`CONFIG_ARM64_VA_BITS_52=y`、
`CONFIG_PGTABLE_LEVELS=5`，但不能据此断言 A57 实际在做 52-bit/five-level walk。
`early_map_kernel()` 在缺少 LPA2 时退回 `VA_BITS_MIN` 并调整 root level；
本次 TCR 的 T0SZ/T1SZ 都为 16，实际 VA 宽度为 48 bit。

复现命令（脚本在抓到高 VA 取指后主动结束调试进程，这是早期切换采样）：

```sh
gdb -q -batch -x docs/mmu/linux-boot.gdb --args \
  qemu/build/qemu-system-aarch64 \
  -machine mini-virt -smp 2 -m 4G -display none -monitor none \
  -serial file:qemu/build/mmu-probe/linux-early.log \
  -kernel linux/build/arch/arm64/boot/Image \
  -dtb linux/build/arch/arm64/boot/dts/demo/mini-virt.dtb \
  -initrd busybox/build/initramfs.cpio.gz \
  -append 'console=ttyAMA0 earlycon=pl011,0x09000000 rdinit=/init panic=-1'
```

另一次使用正常 `run.sh` 完整启动，观察到两个 CPU online、BusyBox shell、
`/sec.bin --all` 的 `sec test: PASS`，最终 `poweroff -f` 正常关机。
早期断点采样与完整启动验证是两次运行，不能把前者的主动退出当作启动失败。

### 12.3 idmap 是否贯穿整个生命周期

**可供特殊切换使用的 idmap 页表可以保留，但不意味着它始终装在 TTBR0，供普通
代码按 PA 数值随意解引用。**

[`setup_arch()`](../linux/arch/arm64/kernel/setup.c) 调用 `cpu_uninstall_idmap()`；
secondary CPU 也在启动流程撤销启动 idmap。
[`mmu_context.h`](../linux/arch/arm64/include/asm/mmu_context.h) 的实现先安装
reserved TTBR0，flush TLB，恢复正常 T0SZ；需要时再安装 active user mm。
正常内核通过 TTBR1 的内核映射运行；TTBR0 管理用户地址空间或保持 reserved。

生命周期中还会为切换 TTBR1、恢复等特殊操作临时 `cpu_install_idmap()`，然后
`cpu_uninstall_idmap()`。应区分：

- `init_idmap_pg_dir`：启动初期构建与过渡使用。
- `idmap_pg_dir`：后续受控切换使用的恒等映射，见 `mmu.c:create_idmap()`。
- `swapper_pg_dir`：正常 kernel VA 映射。

Linux 的 linear/direct map 是另一件事：它给 RAM 建立有规律的 **高 VA -> PA**
映射，通常可以由 `phys_to_virt()`/`virt_to_phys()` 在适用范围内做算术换算，
但绝不等于 VA==PA。kernel image、vmalloc、ioremap、用户映射等也不能一律套用
同一个线性 offset。

所以“MMU enable 后不能访问 PA”更准确的表述是：普通 load/store 不能选择绕过
当前翻译、把操作数直接解释为 PA。要访问某个物理页，先获得映射它的合法 VA；
访问设备则使用合适的 ioremap 和内存属性。恒等映射是其中一种映射，不是豁免 MMU。

## 13. CPU MMU 与 SMMU 的核心区别

二者都做地址翻译、权限检查和翻译缓存，但服务不同的访问发起者。

| 问题 | CPU MMU | 本 mini-virt SMMUv3 |
| --- | --- | --- |
| 谁发起 | CPU 取指、load/store | SEC 等设备 DMA |
| 输入地址 | CPU VA | DMA IOVA |
| 选择上下文 | 当前 EL/regime、TTBR、ASID 等 | SID，必要时 SSID，经 STE/CD 选择上下文 |
| 控制接口 | `MSR/MRS`、TLBI、TTBR/TCR/MAIR | SMMU MMIO、stream/context tables、command queue |
| 出错交给谁 | CPU 同步 Abort，ESR/FAR | DMA fault/event queue，驱动/IOMMU 子系统 |
| QEMU 入口 | TCG inline TLB/helper、ARM walker | DMA AddressSpace、IOMMU MemoryRegion、SMMU translate |
| 本文 addend 快路径 | 用于 TCG 生成的 CPU 访存 | 不是设备 DMA 必经的同一段 JIT 代码 |

本机的 SEC 路径是：

```text
SEC DMA IOVA
  -> VF 对应 SID 的 DMA AddressSpace
  -> SMMUv3 IOMMU translation
  -> guest PA
  -> RAM backing
```

CPU 写 SEC 的 MMIO doorbell 是一次 **CPU** MMU 翻译；设备随后发出的 DMA 又是
一次 **SMMU** 翻译。设备不因 CPU 的 TTBR0 切换就自动使用该进程页表，也不使用
这里的 `mmu_idx=2` 来选 DMA domain。两者最后可以抵达同一物理 RAM。
详细实现和同步协议见已有 [`smmu.md`](smmu.md)。

## 14. 源码阅读索引与体系结构参考

| 要验证的问题 | 本 checkout 的入口 |
| --- | --- |
| guest RAM 从哪里来 | `hw/arm/mini-virt.c:create_ram`；`system/physmem.c:ram_block_add` |
| guest 寄存器状态在哪里 | `target/arm/cpu.h:CPUARMState` |
| mmu_idx 如何定义 | `target/arm/mmuidx.h`、`internals.h`、`tcg/hflags.c` |
| AArch64 load/store 如何生成 IR | `target/arm/tcg/translate-a64.c:do_gpr_ld_memidx` 等 |
| inline lookup 的每条机器码由谁发射 | `tcg/i386/tcg-target.c.inc:prepare_host_addr` |
| tag/addend 如何填充 | `accel/tcg/cputlb.c:tlb_set_page_full`、`tlb_set_compare` |
| helper、victim 与跨页逻辑 | `accel/tcg/cputlb.c:mmu_lookup1/mmu_lookup`、`ldst_common.c.inc` |
| ARM walker 和权限 | `target/arm/ptw.c:get_phys_addr_lpae/get_S1prot` |
| guest fault 如何交付 | `target/arm/tcg/tlb_helper.c:arm_deliver_fault` |
| Linux 过渡到高 VA | `arch/arm64/kernel/head.S`、`kernel/pi/map_kernel.c` |
| idmap 如何撤销 | `arch/arm64/include/asm/mmu_context.h:cpu_uninstall_idmap` |

表内 QEMU 路径相对 `qemu/`，Linux 路径相对 `linux/`；版本相关数字以本文基线为准。
本文结构、代码路径和运行片段来自本 checkout，现代扩展分支不自动代表本 CPU 能力。

体系结构进一步阅读可用 Arm 官方
[AArch64 memory management guide](https://documentation-service.arm.com/static/670e4dc89fbc7343d3e4cee1)：
它将翻译控制、table walk 和 memory attributes 放在同一套体系结构语义下解释。
涉及具体指令编码、TLBI operand、break-before-make 和扩展条件时，应以对应版本的
Arm Architecture Reference Manual 为准。
