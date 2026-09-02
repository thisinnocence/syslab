# QEMU SMMUv3 实现、MemoryRegion 数据路径与并发分析

本文以当前 syslab checkout 为准：QEMU 10.2.0，QEMU 子模块基线
`cf9f4c79a5`，machine 为 `mini-virt`，两个 MTTCG vCPU，SMMUv3 仅启用 Stage 1，
`sec` 是固定 Stream ID 1 的 system-bus DMA master。分析同时对照：

- [Arm SMMU Architecture Specification, IHI 0070 G.a](https://documentation-service.arm.com/static/66c5c097882fec713ef4a8ff)，
  尤其是 3.3、3.5、3.21 和 4.7.3。
- [Arm Architecture Reference Manual, DDI 0487 M.c，VMSAv8-64 4 KiB translation](https://developer.arm.com/documentation/ddi0487/mc/-Part-D-The-AArch64-System-Level-Architecture/-Chapter-D8-The-AArch64-Virtual-Memory-System-Architecture/-D8-2-Translation-process/-D8-2-8-VMSAv8-64-translation-using-the-4KB-granule)。
- [QEMU Multi-threaded TCG](https://www.qemu.org/docs/master/devel/multi-thread-tcg.html)
  和 [Using Multiple IOThreads](https://www.qemu.org/docs/master/devel/multiple-iothreads.html)。

结论先行：

1. SMMU 有两个完全不同的 `MemoryRegion`。`arm-smmuv3` 是 CPU 访问的寄存器
   MMIO；每个 SID 的 `iommu_mr` 是 DMA 地址翻译入口，不是寄存器、页表或 IOTLB。
2. 设备对外仍调用普通 `dma_memory_read()` / `dma_memory_write()`；QEMU memory core
   根据该 DMA `AddressSpace` 的 root 是 `IOMMUMemoryRegion`，回调
   `smmuv3_translate()`，把 IOVA 变为 PA 后继续访问 system memory。
3. “DMA 基本都在 BQL 下”不能作为 QEMU 的通用结论。MMIO callback 默认自动取 BQL，
   但 DMA 到 RAM 的 `address_space_*()` 路径只要求 RCU，不会因为经过 `iommu_mr`
   自动取 BQL；IOThread dataplane 本来就可以在 BQL 外运行。
4. mini-virt 当前 `sec` 是同步 MMIO 设备：guest 写 `SEC_DMA_CMD` 的 callback 内直接完成
   DMA，因此实测整个 DMA 在 BQL 下。它没有异步 BH、timer、worker 或 IOThread，故当前
   实验中 CPU 配 SMMU 与 sec DMA 被 BQL 串行化。
5. SMMUv3 仍有自己的 `s->mutex`。它串行化 config cache、software IOTLB、page-table
   walk 与 invalidation，不能删掉并用 BQL 替代；该锁最初就是为 BQL 外 IO dataplane
   添加的。
6. 对真实硬件，软件不能依赖“正好没撞上 DMA”。STE/CD/PTE 写入、barrier、CFGI/TLBI、
   `CMD_SYNC` 以及最后才允许设备 DMA，是架构协议。Linux driver 按此协议实现。
7. 当前 QEMU 正常翻译与 invalidation 的核心缓存操作有 mutex 保护，但仍存在值得审计的
   BQL 外窗口：translate 解锁后才复制缓存项，fault event queue 也在解锁后更新；MMIO
   寄存器更新本身不取 `s->mutex`。mini-virt 未复现故障，本文将它们标为潜在竞态，
   而不是已经证明的 bug。

## 1. 从硬件语义到 QEMU 对象

### 1.1 Arm SMMUv3 的核心翻译

IHI 0070 3.3 将数据分为两组：

- configuration structures：`StreamID -> STE -> CD`，决定启用哪个 stage、ASID、
  translation table base、地址宽度和属性。
- translation tables：采用 A-profile VMSA descriptor 格式，Stage 1 做 IOVA/VA 到
  IPA/PA，Stage 2 做 IPA 到 PA。

mini-virt 的实际路径只有 Stage 1：

```text
sec transaction(SID=1, IOVA, R/W)
  -> Stream Table[1] -> STE
  -> Context Descriptor 0 -> TTB0/T0SZ/TG0/ASID
  -> VMSAv8-64 page-table walk
  -> PA + permission
  -> system RAM
```

`qemu/hw/arm/smmuv3.c:smmuv3_decode_config()` 对应 `SID -> STE -> CD`；
`qemu/hw/arm/smmu-common.c:smmu_ptw_64_s1()` 对应 Arm ARM 的 VMSAv8-64 walk：根据
granule、input size 和 level 计算 index，读取 64-bit descriptor，区分 table/block/page，
检查 AF/AP 和 output address size，最后产生 `translated_addr`、`addr_mask` 与权限。

QEMU 不是让 host IOMMU 替 guest 走页表。普通 emulated SMMUv3 直接用
`address_space_memory` 读取 guest RAM 中的 STE、CD、command queue 和 PTE；QEMU 自己的
`GHashTable` 只模拟 configuration cache 与 IOTLB。它也不是 cycle-accurate 模型：一次
函数调用就可以完成整个 walk。

### 1.2 两个 MemoryRegion 不要混淆

```text
CPU physical AddressSpace
  0x0b000000..0x0b01ffff -> MemoryRegion "arm-smmuv3"
                              ops = smmu_mem_ops
                              用途 = control-plane MMIO

sec.dma_as (SID 1 AddressSpace)
  0x0..UINT64_MAX -> IOMMUMemoryRegion "smmuv3-iommu-memory-region-1-0"
                      class.translate = smmuv3_translate
                      用途 = data-plane IOVA view
```

第一块由 `smmu_realize()` 通过 `memory_region_init_io()` 创建并由 machine 映射到
`0x0b000000`。第二块由 `smmu_get_address_space()` 按 SID 创建：

```text
SMMUDevice
  sid = 1
  iommu = IOMMUMemoryRegion
  as.root = &iommu

mini-virt.c
  smmu_get_address_space(smmu, 1)
    -> sec_set_dma_address_space(sec, &sdev->as)
```

相关代码：

- `qemu/hw/arm/mini-virt.c:149`：把 SID 1 的 AddressSpace 接给 sec。
- `qemu/hw/arm/smmu-common.c:854`：同一 SID 查找/创建并复用 `SMMUDevice`。
- `qemu/system/memory.c:1777`：`memory_region_init_iommu()` 将 MR 标为
  `terminates = true`，注释中的 “then re-forwards” 是关键：先终止当前 FlatView lookup，
  translate 后再转发到返回的 `target_as`。
- `qemu/hw/arm/smmuv3.c:2035`：QOM class 把通用 `translate` 虚函数绑定为
  `smmuv3_translate()`。

### 1.3 `iommu_mr` 的特点

`IOMMUMemoryRegion` 继承 `MemoryRegion`，自身只额外保存 notifier list/flags；真正的行为在
`IOMMUMemoryRegionClass`：

- `translate()` 返回一个按值传递的 `IOMMUTLBEntry`。
- `IOMMUTLBEntry.target_as` 指定下一层 AddressSpace；SMMUv3 正常路径返回
  `address_space_memory`。
- `iova` 是 entry 覆盖区间的起点，`translated_addr` 是输出地址起点，`addr_mask`
  表示页内 offset mask，例如 `0xfff` 表示 4 KiB mapping。
- `perm` 是 `IOMMU_RO/IOMMU_WO` 权限；权限不符时 memory core 转向 unassigned region，
  DMA API 返回失败。
- 一个 IOMMU 可以通过不同 transaction attributes 选择多个 `iommu_idx`；本模型没有实现
  `attrs_to_index`，通用层默认 index 0。
- translate 的返回信息只在 BQL 或 RCU critical section 内保证有效；需要长期缓存的
  consumer 必须注册 IOMMU notifier。
- 它不是 Linux `struct iommu_domain`，也不保存 guest 的 IOVA mapping。mapping 真值在
  guest RAM 页表，SMMUv3 的 config/IOTLB hash table 只是模拟硬件缓存。

本次 `info mtree -f` 运行结果正好展示了这种分层：

```text
FlatView #1
 AS "smmuv3-iommu-memory-region-1-0"
  0000000000000000-ffffffffffffffff: smmuv3-iommu-memory-region-1-0

FlatView #2
 AS "memory"
  000000000a000000-000000000a0003ff: sec
  000000000b000000-000000000b01ffff: arm-smmuv3
  0000000040000000-000000013fffffff: ram
```

所以 `iommu_mr` 的“地址”不是 SMMU 的 `0x0b000000`。前者覆盖设备可发出的 IOVA
空间，后者才是 CPU 编程 SMMU 的寄存器窗口。

## 2. QEMU data plane：设备 DMA 如何跨框架进入 SMMU

### 2.1 通用框架调用链

`sec_dma_copy()` 对外只使用标准 DMA API：

```text
dma_memory_read(sec.dma_as, src_iova, ...)
  -> dma_memory_rw()
     -> dma_barrier()                       # host smp_mb，不是锁
     -> address_space_rw()
        -> address_space_read_full()
           -> RCU_READ_LOCK_GUARD()
           -> flatview_read()
              -> flatview_translate()
                 -> flatview_do_translate()
                    -> 发现 section->mr 是 IOMMUMemoryRegion
                    -> address_space_translate_iommu()
                       -> imrc->translate()
                          -> smmuv3_translate()
                       -> 校验 perm，组合页内 offset
                       -> 切换到 entry.target_as
                       -> address_space_translate_internal(system memory)
              -> flatview_read_continue()
                 -> RAM memcpy
```

write 路径相同，只是：

- `dma_memory_read()` 表示“device 从 guest memory 读到 device buffer”，所以请求
  `IOMMU_RO`。
- `dma_memory_write()` 表示“device 把 device buffer 写入 guest memory”，所以请求
  `IOMMU_WO`。

`address_space_translate_iommu()` 使用 `do ... while`，因此框架允许一个 IOMMU 的
`target_as` 再落到另一层 IOMMU；最终必须解析到 RAM/MMIO/unassigned region。SMMUv3
只是 memory core 中间的一个翻译 provider，DMA API、FlatView/RCU、QOM 虚函数和最终
RAM access 分属多个 QEMU 核心模块。

### 2.2 SMMUv3 内部翻译链

```text
smmuv3_translate(mr, iova, R/W)
  -> container_of(mr, SMMUDevice, iommu) -> SID
  -> lock(s->mutex)
  -> smmu_enabled()
  -> smmuv3_get_config()
       config-cache hit: 直接得到 SMMUTransCfg
       miss:
         smmu_find_ste() -> smmu_get_ste() -> DMA read guest RAM
         decode_ste()
         smmu_get_cd() -> DMA read guest RAM
         decode_cd() -> stage/asid/ttb/tsz/granule/permission config
         insert configs hash table
  -> smmuv3_do_translate()
     -> smmu_translate()
        -> smmu_iotlb_lookup()
        -> miss: smmu_ptw()
           -> smmu_ptw_64_s1()
              -> get_pte() at each level
              -> validate descriptor/AF/AP/OAS
           -> smmu_iotlb_insert()
  -> unlock(s->mutex)
  -> return target_as/address/mask/perm
```

QEMU software IOTLB key 包含 IOVA、ASID、VMID、translation granule 和 level，因此既能
缓存 page，也能缓存 block mapping。达到 `SMMU_IOTLB_MAX_SIZE` 时当前实现直接清空整个
hash table。

翻译失败时返回 `IOMMU_NONE`，并尝试把 `C_BAD_*`、`F_TRANSLATION`、`F_PERMISSION`
等 event 写到 guest Event Queue，随后触发 EVTQ/GERROR IRQ。成功翻译不会产生 Event
Queue entry。

### 2.3 实测 GDB call stack

QEMU binary 为 debug build（ELF 含 `debug_info`，not stripped）。运行：

```text
qemu-system-aarch64 -machine mini-virt -smp 2 ...
guest: ./sec.bin
```

在第一次 DMA read，即 SID 1、IOVA `0xfffff000` 处：

```text
#0  smmuv3_translate(iommu_mr, 0xfffff000, IOMMU_RO, 0)
#1  address_space_translate_iommu()
#2  flatview_do_translate()
#3  flatview_translate()
#4  flatview_read()
#5  address_space_read_full()
#6  address_space_rw()
#7  dma_memory_rw_relaxed()
#8  dma_memory_rw()
#9  dma_memory_read()
#10 sec_dma_copy()                 qemu/hw/misc/sec.c:74
#11 sec_write(SEC_DMA_CMD=1)       qemu/hw/misc/sec.c:174
#12 memory_region_write_accessor()
#13 access_with_adjusted_size()
#14 memory_region_dispatch_write()
#15 int_st_mmio_leN()
#16 do_st_mmio_leN()
#17 do_st_4()
#18 do_st4_mmu()
#19 helper_stl_mmu()
#20 TCG generated code
#21 cpu_tb_exec()
...
#27 mttcg_cpu_thread_fn()
```

断点现场 `bql_locked() == true`。第二次 DMA write 的 stack 对称：

```text
smmuv3_translate(0xffffe000, IOMMU_WO)
  <- address_space_translate_iommu
  <- flatview_write
  <- address_space_write
  <- address_space_rw
  <- dma_memory_write
  <- sec_dma_copy(qemu/hw/misc/sec.c:81)
  <- sec_write
  <- guest MMIO store
```

trace 同时证明不是绕过翻译：

```text
smmuv3_translate_success ... sid=0x1 iova=0xfffff000 translated=0x40852000 perm=0x3 stage=1
smmuv3_translate_success ... sid=0x1 iova=0xffffe000 translated=0x40857000 perm=0x3 stage=1
sec dma test: PASS (SID 1, IRQ count 1 -> 2)
sec test: PASS
```

PA 会随每次 boot 的分配而变化，不能把上述 `0x40852000/0x40857000` 写成固定 contract。

## 3. QEMU control plane：寄存器、CMDQ 与 cache invalidation

### 3.1 软件不是直接写 QEMU IOTLB

Linux 写的是 guest RAM 中的 STE/CD/PTE 与 CMDQ entry，再写 SMMU MMIO register 通知
设备；QEMU 内部 `configs`/`iotlb` hash table 对 guest 不可见。

以 `CMDQ_PROD` 为 doorbell：

```text
Linux CPU
  -> 在 guest RAM 填 Cmd
  -> dma_wmb()
  -> writel_relaxed(new_prod, SMMU_CMDQ_PROD)

QEMU vCPU thread
  -> guest MMIO store
  -> memory_region_dispatch_write(arm-smmuv3)
  -> smmu_write_mmio()
  -> smmu_writel(A_CMDQ_PROD)
     -> s->cmdq.prod = data
     -> smmuv3_cmdq_consume()
        -> queue_read(address_space_memory)  # 从 guest RAM 取 Cmd
        -> lock(s->mutex)
        -> CFGI: remove config cache
           TLBI: remove software IOTLB entries
           CMD_SYNC: previous command已同步完成，可选发 IRQ
        -> unlock(s->mutex)
        -> queue_cons_incr()
```

在 `offset == A_CMDQ_PROD == 0x98` 的条件断点中，实测 stack 为：

```text
#0 smmu_writel(offset=0x98)
#1 smmu_write_mmio()
#2 memory_region_write_with_attrs_accessor()
#3 access_with_adjusted_size()
#4 memory_region_dispatch_write()
#5 int_st_mmio_leN()
#6 do_st_mmio_leN()
...
#16 tcg_cpu_exec()
#17 mttcg_cpu_thread_fn()
```

该点也实测 `bql_locked() == true`。`smmu_writel()` 随即同步调用
`smmuv3_cmdq_consume()`，并没有独立 command worker。

### 3.2 为什么 QEMU 的 CMD_SYNC 很轻

真实硬件中 command execution、configuration walk、TLB、设备 transaction 都可能并行。
IHI 0070 4.7.3 要求 `CMD_SYNC` 完成时，之前的 CFGI/TLBI 已完成，受影响的旧 transaction
已达到规定的全局可见点，受影响的 in-progress walk 已完成或从头重启。

当前 QEMU model 在写 `CMDQ_PROD` 的调用栈里顺序消费整个队列。每条 CFGI/TLBI 都在
`s->mutex` 内直接修改 hash table；QEMU DMA 本身也是同步的函数调用。因此当前
`SMMU_CMD_SYNC` 分支无需等待模拟时钟或后台 worker，只负责可选 completion IRQ；到它被
消费时，前面的同步操作已经返回。`CONS` 也只在每条命令处理完成后递增。

这是一种合法的“零延迟实现选择”，但不代表真实 SMMU 没有并行，也不能用它研究硬件
queue latency、outstanding transaction 数量或微架构性能。

## 4. 锁、并发域与 BQL

### 4.1 三个不同保护目标

| 机制 | 保护什么 | 不保护什么 |
| --- | --- | --- |
| BQL | 默认 MMIO device callback 与大量 legacy device state | 所有 DMA、guest RAM 内容、IOThread dataplane |
| RCU | `AddressSpace.current_map` / `FlatView` 等 memory topology 的读侧生命周期 | SMMU config/IOTLB hash table、device register state |
| `SMMUv3State.mutex` | config cache、software IOTLB、翻译 walk 与命令 invalidation 的互斥 | MMIO register writes、解锁后的 Event Queue 更新、整个下游 RAM transaction 生命周期 |

另外，`dma_memory_*()` 的 `dma_barrier()` 当前是 `smp_mb()`，用于 host 内存访问排序，
不是 mutual exclusion。`AddressSpace.map_client_list_lock` 保护 map client/bounce-buffer
callback list，也不是 SMMU 翻译锁。

### 4.2 MMIO 为什么在 BQL 下

QEMU `system/physmem.c:prepare_mmio_access()` 的逻辑是：若当前未持有 BQL 且目标
`MemoryRegion.lockless_io == false`，则先取 BQL，callback 返回后释放。QEMU MTTCG 文档
也明确说明普通 MMIO 自动由 BQL 串行化，选择 lockless IO 的设备必须自己加锁。

本次 GDB 还显示：一个 vCPU 停在 SMMU/SEC callback 时，main thread 阻塞在 BQL，另一个
vCPU thread 也不能同时进入普通 MMIO device callback。这解释了当前 mini-virt 的观察结果。

但注意 BQL 是在已解析到“非 direct MR”后由 `prepare_mmio_access()` 获取的。DMA 的目标若
最终是 RAM，走 direct memory path；`iommu_mr` 通过 class `translate()` 被调用，也不是一次
`MemoryRegionOps.read/write` MMIO dispatch。因此：

```text
IOThread/device worker
  -> dma_memory_read(iommu AddressSpace)
  -> RCU + smmuv3_translate
  -> RAM
```

可以从头到尾没有 BQL。QEMU 添加 SMMU mutex 的提交 `32cfd7f39e` 也直接说明：config cache
可能在无 BQL 的 IO dataplane 中访问，该 mutex 以后也用于 IOTLB。

### 4.3 mini-virt 当前为什么仍然安全地落在 BQL 下

`sec_write(SEC_DMA_CMD)` 在普通 MMIO callback 内直接调用 `sec_dma_copy()`；read、write、
IRQ raise 全部在 callback 返回前完成。没有：

- `memory_region_set_lockless()`；
- IOThread/AioContext；
- BH/timer/coroutine/worker thread；
- 把 DMA 请求排队后再异步执行。

所以对“当前 mini-virt 正常测试”可以说：SMMU 配置 MMIO、sec 寄存器和 sec DMA 都被 BQL
串行；`s->mutex` 在这条路径上形成额外保护。不能把这个结论推广到 virtio/vhost/VFIO、
带 IOThread 的 block/network device，或未来把 sec 改为异步的版本。

## 5. 多核软件更新页表/配置时会不会撞上 DMA

### 5.1 真实硬件的答案：会并行，所以必须遵守协议

IHI 0070 明确允许 SMMU 在任意时刻读取 reachable STE/CD，并允许一个结构内的多个
64-bit word 以不同时间顺序读取。若软件直接多 word 改一个仍有效的结构，SMMU 可能缓存
新旧字段混合的状态。

初始化或破坏性更新的通用顺序是：

```text
V=0
  -> 填其它字段
  -> DSB，使数据对 SMMU 可见
  -> CMD_CFGI_* + CMD_SYNC
  -> 原子地设置 V=1
  -> DSB
  -> CMD_CFGI_*
  -> 若随后要启动 DMA，再 CMD_SYNC 并等待
  -> 最后允许 device 发 transaction
```

对已有 translation 的更新还要遵循 Arm ARM/SMMU 的 break-before-make 规则，并在适当时机
执行 `CMD_TLBI_* + CMD_SYNC`。`CMD_SYNC` 是软件知道“旧 cache/walk/transaction 已越过
完成点”的架构接口，不是“等一段估计时间”。

因此问题中的场景要分两种：

- 另一个 core 在准备尚未发布的 table：允许。只要旧结构没有指向它，SMMU 不可达；
  barrier 和最后的 valid/pointer publish 建立顺序。
- 另一个 core 在无协议地修改当前有效 STE/CD/PTE，同时 device DMA：当然会竞争，结果可能
  是旧翻译、新翻译、fault，甚至架构定义的非法中间状态。这是软件错误，BQL 与真实硬件
  无关。

### 5.2 Linux 如何处理多个 CPU 同时发 SMMU 命令

`arm_smmu_cmdq_issue_cmdlist()` 不是靠一个粗粒度 mutex：

1. 用 `cmpxchg_relaxed()` 原子预留 queue slots。
2. 各 CPU 写自己的 command entries。
3. `dma_wmb()` 后设置 valid map，保证 command/data structure 先于 producer publish 可见。
4. owner 才写 `CMDQ_PROD`，并用 release ordering 把 ownership 交给下一 CPU。
5. 请求 sync 的调用者轮询到自己的 `CMD_SYNC` 被消费才返回。

driver 注释明确承诺：两个 CPU 竞争插入 command list 时，每个 list 内不交叉，两个 list
存在一个全序。它也承诺 command publish 前的 `dma_wmb()` 可以排序之前的 STE/CD/PTE
写入。

STE 更新由 `arm_smmu_write_ste()` 分析哪些 qword 正在使用：单个 critical qword 可作
64-bit hitless update；多个正在使用的 qword 要先清 V、更新其它 qword、最后以单个 64-bit
store 恢复 V。每次需要同步的 `entry_set()` 都发 `CMD_CFGI_STE + CMD_SYNC`。

page table 的并发由 io-pgtable 实现处理：新下级 table 先填好，`dma_wmb()` 后用
`cmpxchg64_relaxed()` 安装 parent descriptor；leaf mapping 完成后 `wmb()` 才允许调用者
继续并启动 DMA。unmap 则先清 PTE，再聚合 TLBI，`iommu_iotlb_sync()` 最终等待同步完成。
mini-virt 配置 `CONFIG_IOMMU_DEFAULT_DMA_STRICT=y`，不会把旧 IOVA 很久以后才 flush。

`sec` driver 只有在 `dmam_alloc_coherent()` 返回 DMA address 后才把地址写进设备并下发
`SEC_DMA_CMD`，所以不会把一个“尚未完成 mapping”的 IOVA 提前交给设备。

### 5.3 QEMU 如何模拟这套顺序

在当前同步模型中：

- guest 对 command entry/STE/CD/PTE 的 barrier 由 MTTCG memory-order machinery 与 host
  barriers 表达；Linux 在写 `CMDQ_PROD` 前有 `dma_wmb()`。
- `CMDQ_PROD` MMIO callback 读 guest RAM command；这正对应 Arm queue 规则“consumer
  看到新 PROD 时必须已能看到 entry”。
- CFGI 与 TLBI 在 `s->mutex` 下同步删除 QEMU cache；并发的 BQL 外
  `smmuv3_translate()` 也要取同一 mutex，所以一个 translation 不会和 cache hash-table
  删除/page walk 的核心区同时执行。
- QEMU 不缓存 translation fault。全新 IOVA mapping 原来没有 positive IOTLB entry，PTE
  publish 后首次 DMA 会 walk 新表；unmap/update 才需要 TLBI 删除 positive entry。

在 mini-virt 中还有 BQL，把控制 MMIO 与同步 sec DMA 整体串行化，因此“一个 vCPU 正在
写 SMMU doorbell，sec 同时开始 DMA”的 host callback 级交叠不会发生。

## 6. 当前代码的并发审计结果

### 6.1 已有明确保护的部分

- `smmuv3_translate()` 从 enable/config lookup、STE/CD decode、IOTLB lookup、page walk 到
  IOTLB insert 均在 `s->mutex` 下。
- `smmuv3_cmdq_consume()` 对 CFGI/TLBI/notifier 操作取同一个 mutex，所以 cache container
  不会同时被 lookup/insert/remove。
- command queue 的 MMIO producer 在 BQL 下，多个 vCPU 不会同时修改 `cmdq.prod/cons`。
- 当前 sec 所有可变寄存器和同步 DMA 都在 BQL 下，不需要额外 sec mutex。
- memory core 在 `address_space_read/write()` 使用 RCU，使 DMA 翻译期间看到的 FlatView
  与 MemoryRegion 生命周期稳定。

### 6.2 潜在 BQL 外竞态窗口

以下是基于当前源码的静态审计结论，尚未用 TSAN/stress reproducer 证明：

1. `smmuv3_translate()` 在 `qemu_mutex_unlock(&s->mutex)` 之后才读取
   `cached_entry->entry` 和 `cfg->stage` 来构造返回值。另一线程此时可通过 CFGI/TLBI 在
   mutex 内从 hash table remove 并 free 这些对象，存在 stale pointer/UAF 风险窗口。
   更稳妥的实现应在解锁前把所有返回所需字段复制到局部按值对象。
2. translation fault 的 `smmuv3_record_event()` 在解锁后更新 `eventq.prod`、写 queue 和触发
   IRQ。多个无 BQL DMA producer 同时 fault，或与 guest 更新 EVENTQ register 并发时，
   当前看不到覆盖整个 Event Queue producer state 的 mutex。
3. `smmu_writel()/smmu_writell()` 更新 `cr[]`、`gbpa`、STRTAB/CMDQ/EVENTQ base/index 时
   依赖 MMIO BQL，却不取 `s->mutex`。一个 BQL 外 dataplane translation 读取这些字段时，
   BQL 与 SMMU mutex 之间没有共同同步点。架构上软件应在改全局配置前 quiesce traffic，
   但 hostile/buggy guest 仍可能制造 host C data race；device model 不应把 guest 合规性当成
   host thread-safety 的唯一保证。
4. mutex 只覆盖地址翻译，返回 `IOMMUTLBEntry` 后的最终 RAM read/write 已不在 mutex 内。
   非 BQL dataplane 下，TLBI + `CMD_SYNC` 可能在一个已取得旧翻译、但尚未完成最终 memory
   access 的 transaction 中间运行。真实架构要求 sync completion 对受影响的旧 transaction
   提供完成保证；当前 mini-virt 由外围 BQL 避免此窗口，但通用模型是否完全满足无 BQL
   dataplane 的 completion 语义，需要专门测试和可能的 transaction-lifetime 设计。

这几项不影响本文已经运行通过的 mini-virt 同步正常路径。若要把结论扩展到真实 IOThread
device，应至少增加：两个并发 DMA worker、并行 TLBI/CFGI、fault storm、ThreadSanitizer，
以及“CMD_SYNC 返回后旧 PA 不再被访问”的行为断言。

## 7. 可复现实验

构建与运行：

```sh
./vm/aarch64/mini-virt/build-all.sh
./vm/aarch64/mini-virt/run.sh
```

本次 QEMU 已是 debug build；若重新配置，可临时给 QEMU configure 加 `--enable-debug`。
建议断点：

```gdb
break smmu_writel if offset == 0x98
break smmuv3_cmdq_consume
break smmuv3_translate
break smmu_ptw_64_s1
```

每个断点可检查：

```gdb
bt 30
p bql_locked()
info threads
```

translation trace：

```sh
qemu/build/qemu-system-aarch64 \
  -machine mini-virt -smp 2 -m 4G -nographic \
  -kernel linux/build/arch/arm64/boot/Image \
  -dtb linux/build/arch/arm64/boot/dts/demo/mini-virt.dtb \
  -initrd busybox/build/initramfs.cpio.gz \
  -append "console=ttyAMA0 earlycon=pl011,0x09000000 rdinit=/init panic=-1" \
  -trace 'smmuv3_translate_success'
```

guest 执行 `./sec.bin`，再进 monitor 执行 `info mtree -f`。验收必须同时看到 SID 1 的
独立 AddressSpace、Stage 1 translation trace、payload/IRQ PASS；只有 Linux probe 或
payload 相等都不足以排除 DMA 绕过 SMMU。

## 8. 实现边界

当前实验没有覆盖 PCIe、ATS、PRI、PASID/SVA、stall model 和 Stage 2/nested data path。
QEMU source 还明确标有 STE/CD/PTE “TODO: guarantee 64-bit single-copy atomicity”，HTTU
也未实现；若把本文用于硬件 sign-off，还必须另行验证 interconnect ordering、cache
coherency、outstanding transaction、TLB/walk-cache 微架构、CDC、reset/power、性能与形式
验证。QEMU 在这里验证的是 architected software contract 和功能行为，不是硬件时序实现。
