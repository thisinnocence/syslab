# SMMUv3 System-Bus DMA

mini-virt 使用现有 QEMU SMMUv3 model 与 Linux `arm-smmu-v3` driver，为 SEC 的四个片内 VF
提供独立 Stage 1 DMA 地址空间。VF0–VF3 分别使用 SID 1–4；同一个 IOVA 在不同 VF 下可以
映射到不同 PA。

当前范围包含正常 coherent DMA、多个 stream 隔离、映射撤销与未映射 IOVA fault。
PCIe、ITS/MSI、ATS/PRI、PASID/SVA、Stage 2 和跨 VM 直通不在本实验范围内。

## 拓扑与资源

```text
CPU ──MMIO──> SMMUv3 @ 0x0b000000 ──> CMDQ / EVTQ / 页表位于 RAM
 |
 +──MMIO──> SEC VF0 @ 0x0a000000 ── SID 1 + IOVA ──┐
 +──MMIO──> SEC VF1 @ 0x0a001000 ── SID 2 + IOVA ──┤
 +──MMIO──> SEC VF2 @ 0x0a002000 ── SID 3 + IOVA ──┤
 +──MMIO──> SEC VF3 @ 0x0a003000 ── SID 4 + IOVA ──┘
                                                  |
                                     SMMUv3 STE → CD → Stage 1 页表
                                                  |
                                                 PA → RAM
```

| Resource | Value |
| --- | --- |
| SMMUv3 MMIO | `0x0b000000-0x0b01ffff`，128 KiB |
| eventq IRQ | SPI 3 / INTID 35，edge rising |
| priq IRQ | SPI 4 / INTID 36，当前不启用 PRI |
| cmdq-sync IRQ | SPI 5 / INTID 37 |
| gerror IRQ | SPI 6 / INTID 38 |
| SEC completion IRQ | SPI 8–11 / INTID 40–43，分别对应 VF0–VF3，level-high |
| SEC SID | 1–4，分别选择各自 STE |
| coherency | SMMU 和四个 VF 的 DT 节点均声明 `dma-coherent` |

CPU 通过 SMMU MMIO 和队列建立翻译配置，这是 control plane；VF 的 DMA 经 SID 选择
翻译入口并访问 RAM，这是 data plane。probe 成功只能证明前者，实际 DMA trace 才能证明
后者使用了正确的 SID 和页表。

DTS 的 SMMU 节点使用 `compatible = "arm,smmu-v3"`、`#iommu-cells = <1>`。
四个 VF 是独立 client 节点，例如 VF1：

```dts
sec@a001000 {
	compatible = "syslab,sec-vf";
	reg = <0x00 0x0a001000 0x00 0x1000>;
	interrupts = <0x00 0x09 0x04>;
	iommus = <&smmu 2>;
	dma-coherent;
};
```

machine 与 DT 的 SID 必须相同。SEC 的只读 SID register 使驱动可以在 probe 时检查这项
契约；不匹配则报错，而不是让 DMA 误入未配置或其他 VF 的 stream。

## QEMU 接入边界

```text
mini-virt.create_sec()
    -> 对 VF i 调用 smmu_get_address_space(smmu, i + 1)
        -> 当前 SMMU 实例的 SID table
        -> SMMUDevice → IOMMUMemoryRegion → AddressSpace
    -> sec_set_dma_address_space(sec, i, i + 1, as)
        -> SecVF[i].dma_as
```

一个 `SMMUDevice` 表示一个 stream 的接入上下文，不必对应一个完整物理 IP。一个 SEC
包含四个 `SecVF`，因此可以绑定四个 `SMMUDevice`。SID table 属于 SMMU 实例；同一实例的
同 SID 复用地址空间。当前 machine 只创建一个 SMMU，本次多 VF 不扩展或验证多 SMMU 拓扑。

SMMU 本身是 SysBusDevice。既有 PCI frontend 根据 bus/devfn 动态获取 BDF；固定 SID
frontend 由 `system-bus-masters=true` 开启。两者复用 translation、configuration cache、
IOTLB、invalidation 和 fault generation；本次 SEC 多 VF 无需修改 SMMU common/core。

SEC 使用当前 VF 的 `dma_memory_read/write()`，禁止以系统物理 AddressSpace 替代。
可观察的调用链为：

```text
sec_write → sec_dma_copy(SecVF)
    → dma_memory_read/write(vf->dma_as)
    → address_space_rw → address_space_translate_iommu
    → smmuv3_translate → RAM
```

## Linux 映射边界

内核配置保持 `CONFIG_IOMMU_SUPPORT=y`、`CONFIG_ARM_SMMU_V3=y` 和
`CONFIG_IOMMU_DEFAULT_DMA_STRICT=y`。四个独立 platform device 各有默认 DMA domain；
不能用一个 device 的 DMA API 分配所有 VF buffer，然后仅在设备寄存器里切换 SID。

| Component | Responsibility |
| --- | --- |
| `arm-smmu-v3` | SMMU register、STE/CD、CMDQ/EVTQ、页表与 IOTLB |
| generic IOMMU DMA layer | 每个 VF 的 DMA domain、IOVA 分配和 mapping |
| SEC driver | 使用当前 VF 的 device 分配 buffer，写入 `dma_addr_t`，处理完成 IRQ |
| userspace | 通过 `/dev/secN` 传递 payload，核对结果与 IRQ count |

每个 VF 的两个 coherent buffer 均为 64 bytes。驱动在提交 DMA 前使用 `dma_wmb()`，
完成后使用 `dma_rmb()`；不假设 IOVA 等于 PA。probe 打印 IOVA→PA 是验证信息，不是供
用户态编程的地址 ABI。

## 正常路径与隔离验证

host 构建后运行 `./vm/aarch64/mini-virt/run.sh`，guest 执行：

```sh
ls -l /sys/kernel/iommu_groups/*/devices
./sec.bin --all
echo $?
cat /proc/interrupts
```

本次运行四个 VF 分别进入 group 0–3；编号由 Linux 分配，验收关注四组互相独立。
probe 的一次实测如下，PA 随内核布局和分配顺序变化：

| VF / SID | source IOVA → PA | destination IOVA → PA |
| --- | --- | --- |
| 0 / 1 | `0xfffff000 → 0x40a00000` | `0xffffe000 → 0x40a05000` |
| 1 / 2 | `0xfffff000 → 0x40a09000` | `0xffffe000 → 0x40a0d000` |
| 2 / 3 | `0xfffff000 → 0x40a12000` | `0xffffe000 → 0x40a16000` |
| 3 / 4 | `0xfffff000 → 0x40a1c000` | `0xffffe000 → 0x40a20000` |

这组相同 IOVA、不同 PA 的结果，加上四进程不同 payload 的并发检查，可验证各 stream
没有误用同一翻译上下文。正常模式每个子进程完成 200 轮 XOR/DMA，准确增加 400 次 IRQ。

使用 `Ctrl-a c` 进入 QEMU monitor：

```text
info mtree -f
trace-event smmuv3_translate_success on
```

FlatView 应包含四个 `sec-vf0`–`sec-vf3` MMIO 窗口、SMMUv3 register 区域，以及四个
`smmuv3-iommu-memory-region-<SID>-...` AddressSpace。切回 guest 运行测试，trace 应同时
显示 SID 1–4、相应 IOVA→PA 和 `stage=1`，例如：

```text
smmuv3_translate_success smmuv3-iommu-memory-region-1-0 sid=0x1 iova=0xfffff000 translated=0x40a00000 perm=0x3 stage=1
```

完成后在 monitor 执行 `trace-event smmuv3_translate_success off`。payload 正确、独立
IOMMU group、独立 AddressSpace、实际翻译 trace 共同构成证据，不能只看 probe 成功。

## 映射失效与故障恢复

host 使用 `SEC_FAULT_TEST=1 ./vm/aarch64/mini-virt/run.sh`，guest 执行：

```sh
./sec.bin --all --fault
echo $?
```

`sec.fault_test=1` 只开启受控测试 ioctl，不允许用户指定 DMA address。驱动要求 strict
DMA domain，测试过程如下：

1. 创建临时 buffer，以当前 VF 的 device 执行 `dma_map_single()`。
2. 使用该 mapping 完成一次 copy，验证 payload 并预热 SMMU IOTLB。
3. 执行 `dma_unmap_single()`，strict 模式等待 IOTLB invalidation 完成。
4. 用 `iommu_iova_to_phys()` 确认旧 IOVA 已无映射，再使用它提交一次 4-byte DMA。
5. 要求 SEC 返回 ERROR、完成 IRQ 到达、destination 哨兵保持不变。
6. 用户态继续正常 copy，验证该 VF 可以恢复；并发时其他 VF 的数据和 IRQ 仍正确。

旧 IOVA 重用期间持有当前 VF 的事务锁，没有其他 SEC 请求分配该 domain 的 IOVA。
测试结束才释放临时 CPU buffer，整个失败路径不接受任意地址注入。

本次日志出现 SID 1–4 的 `event 0x10`（`F_TRANSLATION`）事件，以及各 VF 的
`unmapped IOVA ... rejected`。一次受控测试有两次 SEC IRQ：有效 copy 和无效 copy 各一次。
四进程阶段只对 VF0 注入额外一次 fault，因此 VF0 为 402 次 IRQ，其余仍为 400 次；全部
通过并正常关机。SMMU EVTQ 的中断次数可能因事件合并而小于 fault 数，不以一事件一 IRQ
作为验收标准。

本地证据位于 `qemu/build/sec-vf-normal.log` 和 `qemu/build/sec-vf-fault.log`。本实验验证
Stage 1 DMA 隔离与失效，不代表已具备不可信 VM 间的 Stage 2 安全隔离或完整 VF 直通。
