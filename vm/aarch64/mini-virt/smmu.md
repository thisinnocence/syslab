# SMMUv3 System-Bus DMA

mini-virt 使用 QEMU architected SMMUv3 model 和 Linux `arm-smmu-v3` driver，验证一个
不经过 PCIe 的 system-bus DMA master。sec 固定使用 Stream ID 1，经 SMMUv3 Stage 1
translation 访问 RAM。

这个实验只覆盖 SMMU 的最小核心路径：SID 选择 translation context，Linux DMA API 建立
IOVA mapping，device 使用 IOVA 发起 transaction，SMMU page-table walk 得到 PA。PCIe、
ITS、MSI、ATS、PRI、PASID、SVA、Stage 2 和 nested translation 均不在当前范围内。

## Topology

```text
CPU
 |
 +---------------------> SMMUv3 MMIO @ 0x0b000000
 |                         |
 |                         +-> CMDQ / EVTQ in RAM
 |
 +---------------------> sec MMIO @ 0x0a000000
                           |
                           | DMA transaction: SID 1 + IOVA
                           v
                        SMMUv3 Stage 1
                           |
                           | translated PA
                           v
                          RAM @ 0x40000000

SMMUv3 event/error IRQ ---------------------> GICv3 SPI 3-6
sec completion IRQ ------------------------> GICv3 SPI 2
```

SMMUv3 有两个不同的软件可见角色：

- control plane：CPU 通过 MMIO 配置 SMMU，command queue 下发 invalidation 等命令，
  event queue 报告 translation fault。
- data plane：sec 发出的 DMA address 进入 SID 1 对应的 IOMMU AddressSpace，经 Stream
  Table Entry、Context Descriptor 和 translation table 转换后访问 RAM。

只有 driver probe 成功只能证明 control plane 初始化。`sec.bin` 的 DMA copy 和 QEMU
translation trace 用于证明 data plane 实际经过 SMMU。

## Resource Contract

| Resource | Value | Meaning |
| --- | ---: | --- |
| SMMUv3 MMIO | `0x0b000000-0x0b01ffff` | 128 KiB architected register space |
| eventq IRQ | SPI 3 / INTID 35 | Event Queue not empty，edge rising |
| priq IRQ | SPI 4 / INTID 36 | 当前不启用 PRI，保留 architected wiring |
| cmdq-sync IRQ | SPI 5 / INTID 37 | command synchronization，edge rising |
| gerror IRQ | SPI 6 / INTID 38 | global error，edge rising |
| sec Stream ID | `1` | 选择 sec 的 Stream Table Entry |
| translation | Stage 1 | IOVA to PA |
| coherency | coherent | DT 中 SMMU 和 sec 均声明 `dma-coherent` |

DT 中由 SMMU node 描述 provider，由 sec node 的 `iommus` property 描述 client：

```dts
smmu: iommu@b000000 {
	compatible = "arm,smmu-v3";
	reg = <0x00 0x0b000000 0x00 0x20000>;
	interrupts = <0x00 0x03 0x01>,
		     <0x00 0x04 0x01>,
		     <0x00 0x05 0x01>,
		     <0x00 0x06 0x01>;
	interrupt-names = "eventq", "priq", "cmdq-sync", "gerror";
	#iommu-cells = <1>;
	dma-coherent;
};

sec@a000000 {
	compatible = "syslab,sec";
	reg = <0x00 0x0a000000 0x00 0x400>;
	interrupts = <0x00 0x02 0x04>;
	iommus = <&smmu 1>;
	dma-coherent;
};
```

`#iommu-cells = <1>` 表示 client specifier 包含一个 cell；这里的值 1 就是 sec SID。
QEMU machine 和 DT 必须使用同一个值，否则 Linux 配置的是一个 stream，而 device DMA
进入另一个 stream。

## QEMU Integration

QEMU SMMUv3 core 使用 `IOMMUMemoryRegion` 表示每个 stream 的翻译入口。原有 ARM `virt`
machine 通过 PCI bus 和 devfn 生成 BDF，并把 BDF 作为 SID。mini-virt 不创建 PCI bus，
因此 SMMU common code 提供显式 SID 接口：

```text
smmu_get_address_space(smmu, SID 1)
    -> SMMUDevice.sid = 1
    -> IOMMUMemoryRegion
    -> AddressSpace
    -> sec.dma_as
```

system-bus frontend 使用显式 SID table，PCI frontend 则继续在访问时根据当前 bus number
和 devfn 生成 SID，避免改变 PCI bus number 延迟确定的原有行为。两类 frontend 创建的
`SMMUDevice` 共用 translation、configuration cache、IOTLB、invalidation 和 event generation。
`system-bus-masters=true` 只由 mini-virt machine 显式设置；其他 machine 未连接
`primary-bus` 时仍按原 contract 报错。

sec model 调用 `dma_memory_read()` 和 `dma_memory_write()` 访问这个 AddressSpace。若直接
使用 `address_space_memory`，DMA address 会绕过 SMMU，即使 Linux probe 和 IOMMU group
看起来正常，也不能证明 translation data path。

## Linux Driver Boundary

kernel config 启用：

```text
CONFIG_IOMMU_SUPPORT=y
CONFIG_ARM_SMMU_V3=y
CONFIG_IOMMU_DEFAULT_DMA_STRICT=y
```

职责保持分离：

| Component | Responsibility |
| --- | --- |
| `arm-smmu-v3` | SMMU register、CMDQ/EVTQ、STE/CD、page table 和 IOTLB |
| generic IOMMU DMA layer | 为 sec 建立默认 DMA domain 和 IOVA mapping |
| sec driver | 使用 `dma_addr_t`，不访问 SMMU register，不假设 IOVA 等于 PA |
| sec userspace test | 通过 `/dev/sec` 验证 payload、IRQ 和 result |

sec probe 使用 `dmam_alloc_coherent()` 分配两个 64-byte buffer。它同时获得 CPU virtual
address 和 device 使用的 `dma_addr_t`：

```text
CPU writes source buffer
    -> dma_wmb()
    -> driver writes source/destination dma_addr_t to sec
    -> sec sends SID 1 + IOVA
    -> SMMUv3 translates IOVA to PA
    -> sec copies data and raises IRQ
    -> handler acknowledges status and complete()
    -> dma_rmb()
    -> CPU checks destination buffer
```

首版 buffer 由 kernel driver 管理。它不 pin userspace page，也不支持 scatter-gather 或
异步 DMA，因此可以单独观察最基本的 SMMU mapping 和 completion contract。

## Verification

构建并启动：

```sh
./vm/aarch64/mini-virt/build-all.sh
./vm/aarch64/mini-virt/run.sh
```

### Control Plane

boot log 应包含：

```text
iommu: Default domain type: Translated
iommu: DMA domain TLB invalidation policy: strict mode
arm-smmu-v3 b000000.iommu: ias 44-bit, oas 44-bit (...)
syslab-sec a000000.sec: Adding to iommu group 0
```

guest 中检查 group：

```sh
ls -l /sys/kernel/iommu_groups/0/devices
```

预期存在指向 `a000000.sec` 的 symlink。

进入 QEMU monitor 执行：

```text
info mtree -f
```

system FlatView 应包含：

```text
000000000b000000-000000000b01ffff: arm-smmuv3
```

还应存在 SID 1 的独立 AddressSpace：

```text
AS "smmuv3-iommu-memory-region-1-..."
```

### Data Plane

guest 中执行：

```sh
./sec.bin
echo $?
```

预期包含：

```text
sec irq test: PASS (count 0 -> 1)
sec dma test: PASS (SID 1, IRQ count 1 -> 2)
sec test: PASS
0
```

`/proc/interrupts` 应显示 SMMU event/error IRQ 和 sec completion IRQ；正常 DMA copy 不产生
Event Queue fault，因此 `arm-smmu-v3-evtq` count 可以保持为 0。

调试 translation 时，可用 QEMU trace event `smmuv3_translate_success` 观察 SID、IOVA、
translated address 和 stage。最终验收不能只依赖 payload 相等，因为绕过 SMMU 的直接
memory access 同样可能复制成功；IOMMU group、SID AddressSpace 和 translation trace
共同证明 DMA 走过预期路径。

## Current Boundary

当前实现完成正常 Stage 1 DMA mapping。尚未加入未映射 IOVA fault injection；因此 Event
Queue 的 translation fault、driver fault log 和 sec error recovery 属于下一阶段，不应把
当前成功 copy 描述为已经验证 fault enforcement。
