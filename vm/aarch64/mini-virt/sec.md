# SEC 多 VF 设备

SEC 是 mini-virt 的片内 XOR/DMA accelerator。一个 QEMU `sec` 设备包含四个固定 VF，
每个 VF 拥有独立寄存器、完成中断和 DMA stream。Linux 将每个 VF 作为独立 platform
设备管理，业务进程通过 `/dev/sec0`–`/dev/sec3` 分别使用它们。

这里的 VF 是片内虚拟功能，不是 PCIe SR-IOV VF。当前验证同一个 Linux guest 中的多进程
使用；没有 PF 管理协议、动态 VF 创建、跨 VM 直通或 Stage 2。QEMU 在 MMIO callback 中
同步完成计算和 DMA，多进程可以并发提交，但模型不模拟内部流水线或真实吞吐量。

## 资源与所有权

| VF | MMIO，4 KB 窗口 | GIC SPI / INTID | SID | Linux 字符设备 |
| --- | --- | --- | --- | --- |
| VF0 | `0x0a000000-0x0a000fff` | 8 / 40 | 1 | `/dev/sec0` |
| VF1 | `0x0a001000-0x0a001fff` | 9 / 41 | 2 | `/dev/sec1` |
| VF2 | `0x0a002000-0x0a002fff` | 10 / 42 | 3 | `/dev/sec2` |
| VF3 | `0x0a003000-0x0a003fff` | 11 / 43 | 4 | `/dev/sec3` |

四根 IRQ 都是 level-high。SMMUv3 保持 SPI 3–6，PL011 保持 SPI 1。
`mini-virt.c` 负责全部 MMIO/IRQ/SID 连线；Linux DTS 的四个 `syslab,sec-vf` 节点必须逐一
匹配，每个节点只有自己的 `reg`、`interrupts` 和 `iommus = <&smmu SID>`。

```text
                     一个 SEC 物理设备
/dev/sec0 -> driver0 -> VF0 registers -> AddressSpace(SMMU, SID 1)
/dev/sec1 -> driver1 -> VF1 registers -> AddressSpace(SMMU, SID 2)
/dev/sec2 -> driver2 -> VF2 registers -> AddressSpace(SMMU, SID 3)
/dev/sec3 -> driver3 -> VF3 registers -> AddressSpace(SMMU, SID 4)
                                              |
                                     STE / CD / Stage 1 页表
                                              |
                                             RAM
```

每个 VF 在 Linux 中拥有自己的 `struct device`、DMA domain、两个 coherent buffer、mutex、
completion 和 IRQ count。`dmam_alloc_coherent()` 使用当前 VF 的 device，因此相同 IOVA
可以在不同 SID 下映射到不同 PA。单个 Linux device 配置多个 SID 并不自动产生这种隔离。
SMMU 的详细证据见 [`smmu.md`](smmu.md)。

## 寄存器约定

下表偏移均相对于当前 VF 的窗口，支持 little-endian、4 字节对齐的 U32 访问。
保留地址读零、忽略写入；只读寄存器忽略写入并记录 QEMU guest error。

| Register | Offset | Access | Behavior |
| --- | ---: | --- | --- |
| `DATA1` | `0x00` | RW | 第一个 U32 操作数 |
| `DATA2` | `0x04` | RW | 第二个 U32 操作数 |
| `CMD` | `0x08` | RW | 写 1 执行 XOR 并置 IRQ pending；写 0 只清零结果 |
| `RESULT` | `0x0c` | RO | `DATA1 xor DATA2` |
| `IRQ_STATUS` | `0x10` | RW1C | bit 0 为 pending；写 1 清除并撤销 IRQ |
| `DMA_SRC_LO/HI` | `0x14/0x18` | RW | source IOVA 低/高 32 位 |
| `DMA_DST_LO/HI` | `0x1c/0x20` | RW | destination IOVA 低/高 32 位 |
| `DMA_LEN` | `0x24` | RW | QEMU 接受 1–256 bytes |
| `DMA_CMD` | `0x28` | RW | 写 1 经当前 VF 的 AddressSpace 同步复制 |
| `DMA_STATUS` | `0x2c` | RW1C | bit 0 为 DONE，bit 1 为 ERROR；写 1 清对应位 |
| `VF_ID` | `0x30` | RO | VF 编号 0–3 |
| `SID` | `0x34` | RO | machine 绑定的 SID，仅供查询 |
| `RESET` | `0x38` | WO | 写 1 复位当前 VF；读零；其他值忽略 |

DMA source/destination 都是 IOVA。SID 不来自 guest 命令，而由 machine 绑定的
`AddressSpace` 决定，guest 不能通过改寄存器冒用另一个 VF 的 SID。

DMA 长度无效、source 读取失败或 destination 写入失败时，置 ERROR 并产生一次完成 IRQ。
source 读取失败时不会发起 destination 写入；一般的 destination 写失败不承诺事务回滚。
成功时置 DONE 并产生一次完成 IRQ。PIO XOR 与 DMA 共享当前 VF 的 IRQ，驱动串行化同一
VF 的命令，保证 pending 被确认后才开始下一条命令。

单 VF 复位清零所有可写状态和结果、撤销该 VF 的 IRQ，保留 VF_ID、SID 和 DMA 连线；
其他 VF 不变。整机复位依次复位所有启用的 VF。

QEMU `SecState` 包含 `SecVF[]`；设备属性 `num-vfs` 支持 1–4，mini-virt 固定设置为 4。
改变板级 VF 数量需要同步修改 machine 和 DTS。创建时要求每个启用的 VF 都已绑定 DMA
AddressSpace。SEC VMState 更新为版本 4，保存各 VF 的寄存器，校验 VF 数量和 SID，并在
恢复时重新拉起 pending IRQ；不接受旧单 VF 版本 1–3 的 migration stream。当前验收不包含
整机迁移兼容性。

## Linux 与用户态 ABI

驱动由 `CONFIG_SYSLAB_SEC=y` 启用；probe 检查寄存器 SID 与 DTS 中唯一 SID 一致，并要求
translated DMA domain。默认字符设备权限为 `0600`，将节点权限分配给不同业务用户即可
控制使用方。该驱动用于固定板级设备，不提供 sysfs bind/unbind 或 VF 热插拔。

| Operation | Behavior |
| --- | --- |
| `open("/dev/secN", O_RDWR)` | 独占该 VF，其他 open 返回 `EBUSY` |
| `write(struct sec_operands)` | 提交两个 U32 执行 XOR，等待 IRQ handler 后返回 |
| `read(U32)` | 读取该 VF 当前 XOR 结果 |
| `SEC_IOC_CLEAR` | 只清 XOR 结果，不产生 IRQ |
| `SEC_IOC_DMA_COPY` | 同步复制 1–64 bytes，返回 `struct sec_dma_copy.dst` |
| `SEC_IOC_GET_IRQ_COUNT` | 返回该 VF 自 probe 起 handler 处理的累计次数 |
| `SEC_IOC_GET_INFO` | 返回 `vf_id`、`sid`、`max_dma_len` 和能力 flags |
| `SEC_IOC_RESET` | 复位该 VF，清空驱动 buffer/completion；累计 IRQ count 不清零 |
| `SEC_IOC_TEST_FAULT` | 执行受控的有效映射→撤销→旧 IOVA fault 测试，默认禁用 |
| 最后一次 `close` | 复位并清理 VF 后释放独占权；进程异常退出同样处理 |

`fork/dup` 共享同一个 open file description，最后一个引用关闭时才释放 VF。这不是按 PID
授权；共享 fd 的线程/进程属于同一使用方，需要自行协调分离的 `write/read` 操作。
不同 open 的排他性防止无关业务覆盖 XOR 结果。同一 VF 的每个命令由 mutex 保护，不同
VF 不共享这把锁。

UAPI 位于 `linux/include/uapi/linux/sec.h`。DMA 的两个 64-byte buffer 由驱动管理；用户态
只传 payload，不传 IOVA/PA，不涉及 user-page pinning、scatter-gather、异步队列或 mmap。
原 `/dev/sec` 改为 `/dev/sec0`–`/dev/sec3`，原有命令编号和数据结构保留，测试程序默认 VF0。

## 中断、完成与恢复

```text
write / DMA ioctl
    -> 锁住当前 VF，reinit_completion()
    -> 写寄存器、CMD；DMA 提交前 dma_wmb()
    -> QEMU 计算或 DMA，更新状态并拉高该 VF 的 SPI
    -> Linux sec_irq_handler()
         -> 读取状态，W1C DMA_STATUS 和 IRQ_STATUS
         -> 保存状态，irq_count++，complete()
    -> 等待方醒来；DMA 完成后 dma_rmb() 并读取 destination
    -> 解锁并返回
```

handler 不获取事务 mutex，不接触用户地址。正常返回与 IRQ count 的增量共同证明 Linux
handler 已执行；逐命令日志使用 `dev_dbg()`，避免并发测试刷屏。

等待超过 1 秒返回 `ETIMEDOUT`，并复位 VF；DMA ERROR 返回 `EIO`。复位先撤销硬件 IRQ，
再用 `synchronize_irq()` 等待正在运行的 handler，清 completion 和 buffer，避免下一任
使用方消费旧状态。该复位方式依赖当前 QEMU 同步 DMA 模型；若后续加入后台 worker，必须
补充停止/排空 DMA 的协议。

## 验证

host 构建、启动：

```sh
./vm/verify.sh
./vm/aarch64/mini-virt/build-all.sh
./vm/aarch64/mini-virt/run.sh
```

guest 执行：

```sh
ls -l /dev/sec*
./sec.bin
./sec.bin --vf 2
./sec.bin --all
echo $?
cat /proc/interrupts
```

`tests/Makefile` 使用 Linux `headers_install` 导出的 UAPI，以 `-Wall -Wextra -Werror`
编译静态 AArch64 `/sec.bin`，`build-initrd.sh` 将它装入 initramfs。

`--all` 覆盖四个 VF 的所有合法长度、XOR/clear、IRQ count、非法长度/命令、复位、重复
open、dup 最后关闭、四进程并发及 SIGKILL 后重新打开。四个子进程先完成 open，再由父进程
统一放行；每个运行 200 轮不同数据的 XOR/DMA，穿插本地复位，检查结果及准确 IRQ 增量。
单独的复位隔离测试还逐次复位一个 VF，确认其余 VF 的结果和 IRQ count 不变。

关键输出如下，进程完成顺序可以不同：

```text
VF reset isolation: PASS
VF0 concurrent: 200 iterations, 400 IRQs PASS
VF1 concurrent: 200 iterations, 400 IRQs PASS
VF2 concurrent: 200 iterations, 400 IRQs PASS
VF3 concurrent: 200 iterations, 400 IRQs PASS
Four-process data/IRQ isolation: PASS
VF0 killed owner/reopen: PASS
...
sec test: PASS
```

故障验收需重新启动 guest：

```sh
SEC_FAULT_TEST=1 ./vm/aarch64/mini-virt/run.sh
```

该环境变量使 kernel command line 带上 `sec.fault_test=1`。guest 执行：

```sh
./sec.bin --all --fault
echo $?
```

正常启动时 fault ioctl 返回 `EOPNOTSUPP`。开启后，驱动仍要求 strict DMA domain；测试先
创建临时 streaming mapping 并完成一次 copy，随后 `dma_unmap_single()` 撤销映射并完成
IOTLB invalidation，再确认软件页表已没有该映射。驱动用旧 IOVA 发起 4-byte DMA，必须得到 ERROR，
且 destination 的哨兵数据不得改变。用户态不指定测试地址。

每个 VF 单独验证 fault 和恢复；并发阶段 VF0 再注入一次 fault，其 IRQ 增量为 402，其他
VF 仍为 400。内核日志应出现 `unmapped IOVA ... rejected` 和 SMMU 的 `event 0x10`（`F_TRANSLATION`）
事件，之后正常 DMA 必须继续通过。该测试同时检查实际 DMA fault enforcement 与旧映射
失效，详见 [`smmu.md`](smmu.md)。

QEMU qtest 还直接验证了四个 MMIO 窗口的只读身份、保留地址、pending/W1C、非法 DMA
长度、单 VF 复位隔离和整机复位；记录位于 `qemu/build/sec-vf-mmio.log`。

本次正常模式和 fault 模式均通过，均返回 0 并正常关机。完整运行日志保存在本地构建目录
`qemu/build/sec-vf-normal.log`、`qemu/build/sec-vf-fault.log`，构建目录清理后需重新验证。
