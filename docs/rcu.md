# RCU 的由来与 QEMU 实现

本文以当前 syslab checkout 为准：QEMU 10.2.0，QEMU submodule commit
`2aad1b266f`，machine 为 `mini-virt`，使用两个
MTTCG vCPU。文中的『RCU thread』指 QEMU host process 的 userspace RCU thread，
不是 guest Linux 启动日志中的 kernel RCU worker。

RCU 将对象更新拆成发布新版本、等待旧 reader 结束、回收旧版本三个步骤。本文围绕
QEMU 的 FlatView 展开：reader 在临界区内使用地址拓扑，updater 发布新 view，后台
`call_rcu` thread 在安全时机销毁旧 view。

核心收益有三点：

- 读侧成本低：无需共享读锁，减少同一 cache line 的写竞争。
- 新旧访问并行：发布新版本不必等待旧 reader 退出。
- 异步回收：独立的 `call_rcu` 线程承担等待与回收。

具体而言，各 reader 维护自己的临界区状态，由回收端扫描，避免反复修改同一个共享读锁
计数；最外层进入时原子读取 generation 并写入状态标记 `ctr`，退出时以 release store
清零，配合内存屏障保证状态记录与对象访问的顺序。updater 发布新指针后，已持有 old 的
reader 可以继续使用旧对象，取得 new 的 reader 则使用新版本；`call_rcu()` 将回收请求
交给独立线程，等相应 grace period 结束后执行 callback，使 updater 无需原地等待。
这种并行以旧版本暂占内存和回收延迟为代价，读侧仍有必要的原子操作与屏障成本。

## 1. 起源与直觉：切换路由，让在途 packet 用完旧规则

RCU（Read-Copy-Update）由 Paul E. McKenney 和 John D. Slingwine 在 1998 年发表的
《Read-Copy Update: Using Execution History to Solve Concurrency Problems》中系统提出，
目标是降低 read-mostly 并发结构中的同步开销。QEMU 的实现来自 userspace RCU 的
`urcu-mb` 思路，源码版权头也直接注明 Mathieu Desnoyers、Paul E. McKenney 和由
Paolo Bonzini port 到 QEMU。

考虑一个简化的路由切换：发往某目的地址的 packet 原来经网关 A、端口 1 转发，
现在要改经网关 B、端口 2。假设两条路径在过渡期都可用，转发线程只在 RCU 临界区内
读取路由对象，读取完毕后不再保留其裸指针。

CPU 0 正在处理 packet pkt1，已经拿到旧路由对象。此时控制线程若直接原地改字段，pkt1 可能
读到『网关 A + 端口 2』的混合规则；若替换指针后立即释放旧对象，CPU 0 又可能访问到
已释放的内存。RCU 的做法是先构造完整的新路由，再发布新指针，并暂时保留旧路由。

pkt1 继续按旧规则作出转发决定，发布后才开始处理的 packet pkt2 则按新规则处理，无需为切换
而暂停所有转发线程。控制线程只需等待 CPU 不再访问旧路由对象，不是等待 pkt1 到达目的地；
RCU 也不保证网关 A 仍然可达。
这个例子将『完整发布』『新旧并存』『延迟释放』连在一起，QEMU 替换 FlatView 时也是
同样的对象生命周期问题。

还有其他例子：Linux 官方教程也使用链表节点替换、进程链表遍历等场景。
这里用路由切换举例；实际内核路由结构及其引用管理比上述单指针模型更复杂。
参见 [Linux RCU 链表教程](https://cdn.kernel.org/doc/html/latest/RCU/listRCU.html) 和
[What is RCU?](https://cdn.kernel.org/doc/html/latest/RCU/whatisRCU.html)。

### 1.1 不可变对象换版：发布与回收是两件事

以完整替换不可变对象为例，并发读取可能得到三种结果：

| Reader | 看到的对象 | 结果 |
| --- | --- | --- |
| reader A | 完整的 old | 正确 |
| reader B | 完整的 new | 正确 |
| reader | 半旧半新、尚未初始化或已经释放 | 错误 |

updater 先完整初始化 `new`，再按 RCU 发布协议替换入口指针；已取得 `old` 的 reader
继续使用旧对象。发布不会让这些旧指针消失，因此 `old` 必须保留到相应 grace period
结束后才能回收。在这个不可变对象模型中，两份数据各自自洽，业务需要允许旧版本被用完。

```text
fully initialize new -> atomically publish via RCU -> safely access new
remove old           -> wait for grace period      -> safely reclaim old
```

原子替换后立即释放 old，仍会造成 use-after-free；只延迟释放而缺少正确的发布顺序，
也不能保证 reader 看到初始化完成的数据。若发布后还原地修改字段，需要额外的同步协议。

### 1.2 哪些场景允许旧版本继续使用

许多操作关心一次处理内部的自洽，允许新旧版本短暂并存。

下表是一些类似场景举例：

| 领域 / 典型场景 | Reader 正在做什么 | Updater 改什么 | 为什么可以保留旧版本 / 需要什么边界 |
| --- | --- | --- | --- |
| QEMU：AddressSpace 地址拓扑 | vCPU 或 DMA 根据 FlatView 完成地址翻译和 dispatch | 生成并发布新的 FlatView | 已取得旧 view 的访问可沿完整旧地图完成；旧 view 的回收还受引用计数和 grace period 约束 |
| Linux 内核：网络路由查找 | 为 packet 查找转发路径 | 添加、替换或删除路由项 | 在途 packet 可使用已取得的旧路由；前提是业务容忍过渡期的旧路径，RCU 不保证链路仍然可达 |
| Linux 内核：进程链表遍历 | 遍历 task，查找或收集信息 | 创建进程或将退出进程移出链表 | 已取得的 task 不会在访问途中被回收；遍历可能看到或错过并发增删，不是某一时刻的全局进程快照 |
| Linux 内核：文件描述符表扩容 | 根据 fd 查找文件 | 分配更大的 fdtable 并替换旧表 | 正在访问旧表的 reader 可安全完成；表项仍有并发变化，取得具体 file 还需专用查找、引用和校验协议 |
| 中间件：服务发现 / 负载均衡 | 从 backend 列表中选择节点 | 发布扩容、缩容后的节点列表 | 已开始的 request 可按旧列表选节点；缩容要配合连接排空，故障要靠 retry、health check 处理 |
| 日常应用：运行参数 / feature configuration | 按阈值、开关和策略处理一次 request | 发布一整套新参数 | request 进入时固定一份配置，避免计算前后混用参数；要求立刻生效的开关需要额外同步 |

这里的共同点是『读多写少，并允许已经开始的操作用完旧对象』，但要区分两种保证：
完整替换不可变 snapshot，可以让一次操作使用同一版数据；RCU 链表或哈希表的并发遍历，
通常只保证合法访问和对象生命周期，不自动形成整个容器的一致快照。前文的『完整版本』
以不可变对象换版为前提，不能推广为『进入 RCU 临界区后，所有字段和对象都被冻结』。
应用层也可以用不可变对象配合引用计数或 GC 达到类似的换版效果，具体回收机制未必是 RCU。

Linux 示例依据：

- [进程链表与网络路由](https://docs.kernel.org/RCU/listRCU.html)
- [文件描述符表](https://docs.kernel.org/filesystems/files.html)

反过来，权限撤销、余额扣减、锁所有权转移等操作若要求更新后任何 reader 都不能再接受旧
状态，就不能把『短暂读取旧版本』当作正确结果；它们需要锁、版本校验、事务或其他更强的
同步协议。RCU 只保证对象发布和回收的并发生命周期，不自动赋予业务层的旧数据合法性。

这里最容易误解的是名称。RCU 不要求每次修改都真的复制整个对象；关键是 updater 先让旧
版本不再对新 reader 可见，再延迟 reclamation. QEMU 的 FlatView 适合完整换版，链表则可
只更新链接。官方 QEMU RCU 文档把它概括为 removal 与 reclamation 两阶段。

QEMU commit `7911747bd4` 引入基于 `urcu-mb` 的 RCU library，commit [26387f86c9](https://github.com/qemu/qemu/commit/26387f86c9d6ac3a7a93b76108c502646afb6c25) 加入
异步 `call_rcu`；两者 author date 为 2013-05-13，进入当前 Git history 的 commit date
为 2015-02-02。延伸阅读见
[原始 RCU 论文](https://www.eecg.toronto.edu/~amza/ece1747h/papers/rcu.pdf)和
[QEMU 官方 RCU 文档](https://www.qemu.org/docs/master/devel/rcu.html)。

## 2. QEMU RCU 的最小模型

### 2.1 reader：用 TLS 记录临界区状态

每个参与 RCU 的 thread 必须先调用 `rcu_register_thread()`；main thread 在 RCU
constructor 中注册，MTTCG vCPU 在 `mttcg_cpu_thread_fn()` 中注册，显式创建的
`IOThread` 在 `iothread_run()` 中注册。

`IOThread` 是 QEMU 社区提供的正式 framework mechanism，不是留给定制开发者的空壳；
它把一个独立 OS thread、一个 `AioContext` event loop，以及 fd、timer、BH 等异步服务
封装为 QOM `TYPE_IOTHREAD`。当前开源代码确实会启动它：用户创建
`-object iothread,id=io0` 时，`iothread_init()` 调用 `qemu_thread_create()` 进入
`iothread_run()`，`virtio-blk`、`virtio-scsi` 等设备可绑定该对象；QEMU 内部的 monitor
和 VFIO-user 也有按需调用 `iothread_create()` 的路径。该机制由 Stefan Hajnoczi 在
commit [`be8d8537`](https://gitlab.com/qemu-project/qemu/-/commit/be8d8537668c9be7a8dee6aed94b2b3f9fcd4a9f)
引入，author date 为 2014-03-03、commit date 为 2014-03-13；设计目标是把 event-loop
工作分散到多个 host CPU，降低 main loop/BQL 的 I/O 瓶颈，详见
[QEMU IOThread 官方文档](https://www.qemu.org/docs/master/devel/multiple-iothreads.html)。
mini-virt 当前未创建 IOThread，本次运行看到的独立后台线程是 `call_rcu` thread。

每个 thread/coroutine 都有一份源码中的 `struct rcu_reader_data`：

```c
struct rcu_reader_data {
    unsigned long ctr;                  // 当前 RCU counter，0 表示在临界区外
    bool waiting;                       // 回收端是否正在等待本 reader
    unsigned depth;                     // RCU 临界区嵌套层数
    QLIST_ENTRY(rcu_reader_data) node;  // 全局 reader registry 链表节点
    NotifierList force_rcu;             // 催促 reader 经过安全点的 notifier
};
```

这些名字只是 QEMU 实现字段，不是一组通用 RCU 术语；其中 `ctr` 是 `counter` 的缩写，
不是 reader 数量、对象引用计数或对象版本号。

**读侧：`rcu_read_lock()` 记录状态，不获取 mutex。**
`qemu/include/qemu/rcu.h` 中的核心路径是：

```c
static inline void rcu_read_lock(void)
{
    struct rcu_reader_data *p_rcu_reader = get_ptr_rcu_reader();
    unsigned ctr;

    if (p_rcu_reader->depth++ > 0) {
        return;
    }
    // 回收线程会并发更新全局 counter，原子读取避免 data race 和撕裂读取
    ctr = qatomic_read(&rcu_gp_ctr);
    qatomic_set(&p_rcu_reader->ctr, ctr);
    /* 先记录读侧状态，再访问受保护的指针 */
    smp_mb_placeholder();
}

static inline void rcu_read_unlock(void)
{
    struct rcu_reader_data *p_rcu_reader = get_ptr_rcu_reader();

    assert(p_rcu_reader->depth != 0);
    if (--p_rcu_reader->depth > 0) {
        return;
    }
    /* 对象访问先完成，再标记最外层临界区结束 */
    qatomic_store_release(&p_rcu_reader->ctr, 0);
    smp_mb_placeholder();
    if (unlikely(qatomic_read(&p_rcu_reader->waiting))) {
        qatomic_set(&p_rcu_reader->waiting, false);
        qemu_event_set(&rcu_gp_event);
    }
}
```

main thread 在 RCU 初始化时注册；每个 MTTCG vCPU 启动时注册自己的 reader 状态和
force-RCU notifier，退出时注销；显式 IOThread 也在自身 event-loop thread 的入口与出口
完成注册和注销。mini-virt 本次没有创建 block-layer IOThread，不能把可选 IOThread 与
全局 `call_rcu` thread 混为一谈。

### 2.2 updater：发布新对象，等旧 reader 用完

更新端先完整初始化新对象，再用 `qatomic_rcu_set()` 发布；reader 用
`qatomic_rcu_read()` 取得指针。发布顺序保证初始化数据可经该指针被正确访问，
但不保证发布后对对象字段的任意并发修改安全。

移除旧对象后，更新端有两种回收方式：调用 `synchronize_rcu()` 同步等待，然后自行
销毁；或调用 `call_rcu()` 提交 callback，由第 3 节的后台线程等待并销毁。
多个 updater 仍须由 BQL、对象锁或单线程执行串行化，RCU 不处理 writer-writer conflict。

### 2.3 grace period 长度：由 reader 退出决定，不由定时器决定

`grace period` 中文通常译为『宽限期』。在通用 RCU 术语中，它是这样一段等待区间：
宽限期开始前已经进入的 RCU read-side critical section 必须全部结束，旧对象才能被回收。
这里的关键限定是『开始前已经进入』，宽限期开始后才进入的新 reader 不在
本轮等待范围内。这一定义可对照
[Linux Kernel 的 RCU 说明](https://docs.kernel.org/RCU/whatisRCU.html)和
[QEMU RCU 官方文档](https://www.qemu.org/docs/master/devel/rcu.html)。

QEMU 沿用这个概念：updater 先从共享入口移除 `old`，再由 `synchronize_rcu()` 或
`call_rcu()` 等待宽限期结束，最后回收 `old`。它没有预设的毫秒数，而是检查本轮开始前
进入的 reader 是否都退出了当时那次临界区；因此宽限期描述的是一个并发安全条件，不是
『发布后固定等待一段时间』的定时策略，也不要求所有线程同时停止或全系统 reader 数量
同时变成零。

```text
                         grace period begins
                                  |
reader A: enter ------------------|-- exit
reader B:       enter ------------|---------- exit
reader C:                         |  enter ---------------- exit
                                  |             ^
                                  +-------------+
                                    wait for A and B
```

上图中 C 是新 reader，不阻碍这一轮完成。前提仍是 updater 已先从共享入口移除旧对象，
使新 reader 无法再取得它；否则即使等完 grace period，也不能安全释放旧对象。

QEMU 用 reader 记录的 `ctr` 与全局 generation 判断是否仍需等待。在本文的 64-bit host
路径中，`synchronize_rcu()` 推进 generation，`wait_for_readers()` 按以下条件检查：

| Reader 状态 | 是否阻碍本轮完成 | 原因 |
| --- | --- | --- |
| 已在临界区外，`ctr == 0` | 否 | 已结束受保护的访问 |
| 仍在旧 generation 的临界区内 | 是 | 仍可能持有待回收对象 |
| 已退出，又进入新 generation 的临界区 | 否 | 旧的那次访问已经结束 |
| 本轮开始后进入，记录新 generation | 否 | 不属于本轮需要等待的旧 reader |

嵌套 `rcu_read_unlock()` 只有在最外层退出、`depth` 归零时才清除 `ctr`，所以退出内层
函数不一定意味着这个 reader 已完成。32-bit host 的实现另有两阶段处理以避免 generation
回绕问题，不能直接照搬这里的单次推进过程。

等待时长主要由最晚退出的旧 reader 决定，还会叠加线程调度和检测唤醒的延迟。
reader 被抢占、执行很长的循环或在临界区内阻塞，都可能延长等待；如果旧 reader 永不
退出，grace period 就可能一直无法结束，待回收对象也会积压。

`wait_for_readers()` 未进入 forced 模式时每次休眠 10 ms；休眠达到 5 次、callback
积压达到 30 个，或进入 `drain_call_rcu()` 时，会设置 `waiting` 并调用 force-RCU notifier。
MTTCG 的 notifier 通过 `async_run_on_cpu()` 请求 vCPU 经过安全点，随后仍须检查状态并
等待通知。这些是催促策略，不是回收期限，不能因『已经等得够久』而直接释放对象。

还要区分 grace period 和 callback 的总延迟：从 `call_rcu()` 提交到真正销毁对象，
可能还要等后台线程调度、前一批 callback、相应 grace period，以及执行 callback 所需的
BQL。因此 grace period 完成只说明旧 reader 的等待条件已经满足，不表示 callback 已执行。
检测与等待由 RCU 实现负责，程序员则必须保证正确移除对象、遵守临界区边界，并为带出
临界区的指针另行维护引用与回收协议。

### 2.4 RCU 的同步在哪里：原子操作、内存屏障和锁各有分工

RCU 仍然需要原子操作和锁。它降低读侧成本的方式，是让 reader 读取共享指针、记录自己的
临界区状态，避免每次访问都争用同一个 mutex 或 rwlock 的共享锁状态。

| 同步位置 | 当前 QEMU 的机制 | 保护的关系 |
| --- | --- | --- |
| 发布与读取对象指针 | `qatomic_rcu_set()` / `qatomic_rcu_read()` | 原子传递指针，并保证 reader 经该指针访问发布前已初始化的数据 |
| reader 进入与退出 | 原子读写 `ctr`、release store 与 memory barrier | 将临界区内的对象访问和 reader 状态记录正确排序，供回收端判断 |
| 回收端检查 reader | `qatomic_read()`、`smp_mb_global()` 与 generation 协议 | 与读侧配合，避免错误认定旧 reader 已经完成 |
| grace period 与 reader registry | `rcu_sync_lock`、`rcu_registry_lock` | 串行化 grace-period 推进，保护注册、注销和扫描列表 |
| callback 提交与消费 | MPSC 队列的原子操作、原子计数和 event 通知 | 在多个提交线程与单个回收线程之间安全交接任务 |
| 业务对象的更新端 | BQL、对象自己的锁或单线程执行约束 | 串行化多个 updater；RCU 本身不解决 writer-writer conflict |
| callback 执行 | 全局回收线程串行执行，并持有 BQL | callback 之间不并行，并与同样遵守 BQL 的路径互斥；不排斥 BQL 外的所有访问 |

`ctr` 由所属 reader 写、回收端读，因此即使每个 reader 独立维护状态，仍需要原子访问
和内存顺序。回收端必须把状态检测与读侧访问配对，不能只依靠 registry 锁判断安全性。

**回收端：两把 mutex 保护推进过程与 reader 列表。**
`qemu/util/rcu.c` 的 `synchronize_rcu()` 在 64-bit host 上可简化为：

```c
void synchronize_rcu(void)
{
    /* 串行化 grace-period 推进，直到本次等待结束 */
    QEMU_LOCK_GUARD(&rcu_sync_lock);
    smp_mb_global();

    /* 保护 reader registry 的扫描与修改 */
    QEMU_LOCK_GUARD(&rcu_registry_lock);
    if (!QLIST_EMPTY(&registry)) {
        qatomic_set(&rcu_gp_ctr, rcu_gp_ctr + RCU_GP_CTR);
        wait_for_readers();
    }
}
```

`QEMU_LOCK_GUARD()` 在此处取得 mutex，并在离开作用域时自动释放，因此源码不需要在
函数末尾显式写 unlock。这两把锁不要求普通 reader 在每次读操作时获取。
`wait_for_readers()` 扫描时用下列判定识别仍处于旧 generation 的 reader：

```c
static inline int rcu_gp_ongoing(unsigned long *ctr)
{
    unsigned long v;

    v = qatomic_read(ctr);
    return v && (v != rcu_gp_ctr);
}
```

扫描前有 `smp_mb_global()` 与读侧协议配合；确认不再阻碍本轮的 reader 会移到临时列表。
若仍需等待，函数暂时释放 registry 锁，避免在休眠期间堵住线程注册与注销：

```c
/* wait_for_readers() 内的等待片段 */
qemu_mutex_unlock(&rcu_registry_lock);
// forced 表示已通知 reader 推进到静止点，并设置 waiting，等待其退出临界区时发出事件
// 未进入 forced 时先睡眠 10 ms 再扫描，避免忙等；sleeps 累计到 5 次会触发 forced
// 两条路径醒来后都要重新检查 reader 的 ctr，事件到达或睡够时间不代表宽限期结束
if (forced) {
    qemu_event_wait(&rcu_gp_event);
    qemu_event_reset(&rcu_gp_event);
} else {
    g_usleep(10000);
    sleeps++;
}
qemu_mutex_lock(&rcu_registry_lock);
```

这里暂时放开的是 `rcu_registry_lock`，外层 `rcu_sync_lock` 仍持有。
等待结束后重新取得 registry 锁，再检查条件；通知和休眠本身不构成回收依据。

## 3. 为什么有一个独立的 `call_rcu` OS thread

### 3.1 `synchronize_rcu()` 放在 updater 上的问题

QEMU 的拓扑更新经常在持有 BQL 时发生。如果 updater 发布新对象后直接调用
`synchronize_rcu()`，它会停在那里等待 vCPU、IOThread 等旧 reader。等待时间被放进了
管理操作的关键路径；更糟的是，reader 或令其结束临界区所需的路径可能需要 BQL，形成
『我持锁等你，你等锁才能离开』的循环。

QEMU commit [26387f86c9](https://github.com/qemu/qemu/commit/26387f86c9d6ac3a7a93b76108c502646afb6c25) 的原始说明正是：BQL 令同步 `synchronize_rcu()` 很难使用，
因此异步 callback 对 QEMU 尤其重要。QEMU 官方文档也明确建议，无法在等待前释放 BQL
时使用 `call_rcu()`。

### 3.2 独立线程实际做什么

MPSC 是 Multiple Producer, Single Consumer（多生产者、单消费者）的缩写：多个
QEMU 线程可以通过 `call_rcu()` 并发提交 callback，但只有一个独立的 `call_rcu`
线程负责从队列中取出并执行这些 callback。

```text
任意 updater
  call_rcu1(node, func)
    -> enqueue(node)                 全局 MPSC queue，多 producer
    -> rcu_call_count++
    -> wake rcu_call_ready_event

唯一 call_rcu thread                单 consumer
  -> 等 callback 到来
  -> 记下本批 n
  -> synchronize_rcu()              等本批之前的 reader 离开
  -> bql_lock()
  -> 依序执行 n 个 node->func(node)
  -> bql_unlock()
```

只有显式提交给 `call_rcu()` 的 callback 才进入队列；后台线程不会周期性扫描并回收
所有 QEMU 对象。本批回收必须等待相应 grace period.

这里的 grace period 没有固定时长：QEMU 检查已注册 reader 的 `ctr`，确认所有可能
仍使用旧对象的 reader 都已退出相应读侧临界区，才判定本轮结束。等待过程中可以先睡眠
10 ms 再检查，或在进入 forced 模式后等待 reader 退出时发出的事件通知；时间到了或
收到事件都只是触发重新检查，不代表宽限期已经结束。如果某个相关 reader 一直不退出，
宽限期就可能一直无法结束。

**执行端：等待完成后才获取 BQL 并调用 callback。**
`call_rcu_thread()` 的核心顺序如下，省略取批次与队列暂空时的重试分支：

```c
synchronize_rcu();
qatomic_sub(&rcu_call_count, n);
bql_lock();
while (n > 0) {
    node = try_dequeue();
    /* 省略 node 为空时释放 BQL、等待并重新获取的逻辑 */
    n--;
    node->func(node);
}
bql_unlock();
```

因此回收线程等待 grace period 时不持有这里的 BQL，真正执行 callback 时才持有。
这把锁与前面的两个 RCU 内部 mutex 职责不同：它让 callback 与其他遵守 BQL 的业务
路径互斥，不能代替 reader 的 grace-period 协议。

### 3.3 为什么恰好一个，而不是每个 vCPU 一个

当前实现只有一个全局 RCU domain、一个 global generation、一个 callback queue；queue
本身就是 multi-producer/single-consumer。单 consumer 有三个直接结果：

- 所有 subsystem 共用一次 grace-period 检测，能按批回收，不需要每个 vCPU 重复扫描
  全局 reader registry。
- callback 天然串行且保持队列顺序，`drain_call_rcu()` 才能通过在队尾追加 sentinel，
  等它执行来证明此前 callback 已完成。
- callback 都要在 BQL 下执行；增加多个 reclaimer 最终仍会在 BQL 上串行，还会增加
  grace-period 协调、线程和调度成本。

这是对当前实现结构的解释，不是 RCU 理论规定『只能有一个线程』。其他 RCU 实现完全可以
按 CPU 分 callback queue；QEMU 当前选择的是一个全局后台 reclaimer。

reclaimer 意为『回收者』，这里指 QEMU 的 `call_rcu` 后台线程：等待宽限期结束后，
执行已提交的 callback，完成旧对象释放等延迟清理工作。

### 3.4 和 BH 有多像：都延后 callback，但执行条件不同

RCU thread 和 BH（Bottom Half）的共同点是：调用者提交 callback，留到之后执行。
区别在于为什么延后，以及由谁在什么条件下执行：

| 对比项 | RCU thread | BH |
| --- | --- | --- |
| 主要目的 | 等旧 reader 用完对象，再安全回收 | 将工作推迟到所属 event-loop 的执行上下文 |
| 执行条件 | callback 入队后，必须经过相应的 grace period | BH 被调度后，由所属 event-loop 处理；不因此等待 RCU grace period |
| 执行线程 | 专门的全局 `call_rcu` OS thread | 所属 `AioContext` 的线程，通常是 main thread 或 IOThread；BH 自身不是线程 |
| 典型工作 | 销毁旧 FlatView 等已移除对象 | 处理异步完成通知、推进设备状态 |
| 耗时 callback 的影响 | 延误后续回收，并因执行时持有 BQL 而影响其他需要 BQL 的路径 | 占住所属 event-loop，延误其他事件处理 |

因此，可以把 `call_rcu()` 理解为『把等待安全回收时机和最终回收交给后台线程』。
这里移出 updater 路径的关键等待是 reader 退出临界区，销毁对象本身未必耗时；
grace period 提供的是安全回收条件，不是给任意耗时任务安排后台执行的机制。
BH 则提供 event-loop 中的延后执行，也不等于将任务交给独立 worker。
两者都不适合随意塞入长时间阻塞的工作。

RCU callback 的等待与 BQL 范围见本节前述 `qemu/util/rcu.c`；BH 的入队、执行和
删除协议见第 5.3 节及 `qemu/util/async.c`。

### 3.5 callback 如何携带执行上下文

排队执行需要保存两件事：『执行哪个函数』和『操作哪个对象』。BH 显式保存
`callback + void *opaque`；RCU 则把队列节点嵌入待回收对象，让节点指针同时携带对象身份。
这里的上下文是 callback 所需的数据，不是线程的寄存器或调用栈。

**BH：保存 opaque，执行时原样传回。** 以下摘录保留核心字段和语句，省略其他逻辑：

```c
/* include/block/aio.h */
typedef void QEMUBHFunc(void *opaque);

/* util/async.c: QEMUBH 的核心字段 */
struct QEMUBH {
    AioContext *ctx;
    QEMUBHFunc *cb;
    void *opaque;
    /* 其余字段省略 */
};

/* aio_bh_new_full() 创建时绑定 */
.ctx = ctx,
.cb = cb,
.opaque = opaque,

/* aio_bh_call() 执行时传回 */
bh->cb(bh->opaque);
```

`ctx` 决定 BH 属于哪个 event-loop，`opaque` 则指向业务对象；两者分工不同。
callback 内可以将 `opaque` 转回约定的结构体指针，访问设备状态、请求参数或结果缓冲区。
`aio_bh_new_full()` 只创建 BH，之后还需调度；`aio_bh_schedule_oneshot_full()` 则创建并
直接入队，由 `aio_bh_poll()` 取出后调用。

**RCU：队列节点本身指向待回收对象。** 核心代码如下：

```c
/* include/qemu/rcu.h */
typedef void RCUCBFunc(struct rcu_head *head);
struct rcu_head {
    struct rcu_head *next;
    RCUCBFunc *func;
};

/* util/rcu.c: call_rcu1() */
node->func = func;
enqueue(node);
qatomic_inc(&rcu_call_count);
qemu_event_set(&rcu_call_ready_event);

/* call_rcu_thread(): 经过 grace period 后，在 BQL 下执行 */
node->func(node);
```

这里没有单独的 `void *opaque` 字段。以 FlatView 为例，`struct FlatView` 的第一个成员
就是 `struct rcu_head rcu`，`flatview_unref()` 在最后一个引用释放时提交：

```c
call_rcu(view, flatview_destroy, rcu);
```

当前 QEMU 的 `call_rcu()` 宏检查 callback 的参数类型，并用
`offset_must_be_zero[-offsetof(typeof(*(head)), field)]` 要求该成员的 offset 为 0；
随后将 `&view->rcu` 和转换为 `RCUCBFunc *` 的 `flatview_destroy` 传给 `call_rcu1()`。
因此 `view` 与 `&view->rcu` 地址相同，后台执行 `node->func(node)` 时，
`flatview_destroy(FlatView *view)` 就能访问整个旧 FlatView 并释放其资源。
这个宏没有用 `container_of()` 恢复任意偏移的成员；自定义对象使用该宏时，必须同样把
`rcu_head` 放在首部。若直接使用 `call_rcu1()`，则可由接受 `struct rcu_head *` 的
callback 自行通过 `container_of()` 找回外层对象。

两种方式都只传递指针，不复制对象。BH 的 `opaque` 必须由调用方保证在 callback 使用期间
有效，不能指向提交函数返回后已失效的栈变量；oneshot 自动释放的是 BH 自身，不是
`opaque` 指向的业务对象。RCU 对象则必须先从共享结构中移除，再提交延迟回收，提交后不能
由 updater 提前释放。两者携带的对象若仍有并发写入，还需单独的同步协议；传递指针本身
不保护对象内容，也不延长其所引用的其他资源的生命周期。

## 4. AddressSpace / MemoryRegion：RCU 保护的不是树，而是读路径看到的快照

### 4.1 三个对象的分工

```text
MemoryRegion tree                  配置视图：RAM、MMIO、alias、priority、subregion
       |
       | generate_memory_topology()
       v
FlatView                          展平且排序的 immutable address ranges + dispatch tree
       ^
       | AddressSpace.current_map (RCU-published pointer)
AddressSpace                      CPU 或某个 DMA master 看到的地址空间
```

MemoryRegion tree 便于 machine/device 组合地址拓扑，却不适合每次访存都递归解析。QEMU
在 topology transaction commit 时生成新的 FlatView，通知 MemoryListener 后，以
`qatomic_rcu_set(&as->current_map, new_view)` 一次发布。旧 FlatView 的 refcount 到零时不
立即销毁，而是 `call_rcu(view, flatview_destroy, rcu)`。

因此更准确的说法是：

- BQL 保护 topology 的 write side；`memory_region_transaction_commit()` 明确 assert
  BQL，并遍历所有 AddressSpace 更新 view。
- RCU 保护并发 read side 取得的 `AddressSpace.current_map`、FlatView ranges 与 dispatch
  生命周期。
- FlatView 自己还带 refcount，用于需要把 view 带出 RCU 临界区的调用者；
  `address_space_get_flatview()` 在 RCU 内尝试加 ref，若正好已被替换且 ref 为零就重试。

### 4.2 为什么这是 QEMU 的 hot path

`address_space_read_full()` 和 `address_space_write()` 都先进入 RCU 临界区，再取得 FlatView
并完成 translate/dispatch。设备 DMA 的 `dma_memory_read()`、`dma_memory_write()` 最终也
走这里。TCG 更外层的 `cpu_exec()` 本身还有 RCU guard，所以 memory API 的 guard 经常是
嵌套的；嵌套只更新 TLS（Thread-Local Storage，线程局部存储）中的 `depth`，即当前
线程的 RCU 临界区嵌套层数，不重复做完整 generation 协议。

```text
MTTCG vCPU / device / IOThread
  -> address_space_read_full()
     -> RCU_READ_LOCK_GUARD()
     -> address_space_to_flatview()          qatomic_rcu_read(current_map)
     -> flatview_read()
        -> flatview_translate()
        -> RAM access 或 MemoryRegion callback
  -> rcu_read_unlock()
```

mini-virt 本次 GDB 还观察到 SMMUv3 的 command queue DMA read 正在这个路径上，
见第 7 节。

## 5. event-loop：RCU、LockCnt 和 ownership protocol 各管一层

QEMU event-loop 由 `AioContext` 承载 fd handlers、BH、timers 和 polling。这里不能简单写成
『event-loop 用 RCU，所以无锁』：不同列表使用不同的组合协议。

### 5.1 fd handler：先发布新节点，遍历结束后再删旧节点

`aio_set_fd_handler()` 在 `ctx->list_lock` 下构造完整的新 `AioHandler`，通过
`QLIST_INSERT_HEAD_RCU()` 发布；更新或删除旧 handler 时，如果 event-loop 正在遍历，
`aio_remove_fd_handler()` 只把旧节点挂到 `deleted_aio_handlers`。最外层 dispatch/poll
完成后，`aio_free_deleted_handlers()` 才真正 unlink/free。

这里的对象回收依赖 `QemuLockCnt` 确认本 AioContext 没有 walker，并没有把每个
`AioHandler` 都送给全局 `call_rcu` thread。RCU list macro 负责指针发布/遍历的 memory
ordering，LockCnt 负责这一具体对象的安全删除。二者不能互相替代。

### 5.2 busy poll：扩大 RCU 临界区来减少 barrier 次数

`run_poll_handlers()` 在整个 polling loop 外放一个 `RCU_READ_LOCK_GUARD()`。源码注释给出
的理由非常直接：各个 `io_poll()` callback 常含 RCU read critical section，如果每轮都
lock/unlock 会反复执行昂贵的 memory synchronization；外层 guard 令内部嵌套操作只改
`depth`。这是 RCU 在 event-loop 中解决延迟/吞吐问题的直接实例。

代价也很清楚：poll loop 越长，本轮 grace period 越可能被这个 reader 延长，所以代码以
`max_ns` 和 timeout 限制循环。

### 5.3 BH：跨线程投递，但不是 `call_rcu` callback

BH 可由任意线程以 atomic flag 加 `QSLIST_INSERT_HEAD_ATOMIC()` 投递，event-loop 以
atomic move 取得一批并执行；delete 只是投递 `BH_DELETED`，由 consumer dequeue 后释放。
`aio_ctx_check()` 等位置用 `QSLIST_FOREACH_RCU()` 读取已发布链接，但 BH 的 reclamation
依靠 pending/dequeue ownership protocol，不应误称为由独立 RCU thread 回收。

## 6. 替代方案与性能边界

### 6.1 直接删掉 RCU 而不加同步：确定的 lifetime bug

假设 vCPU 已从 `as->current_map` 读到 old FlatView，main thread 此时 commit 新拓扑：

```text
vCPU                         main thread
----                         -----------
fv = as->current_map  # old
                             as->current_map = new
                             flatview_destroy(old)
flatview_translate(fv)       # ranges/dispatch 已释放：use-after-free
```

可能结果是错误地落入 unassigned region、调用已销毁 MemoryRegion 的 ops、host crash，或
只在压力下出现的 silent memory corruption。`qatomic_rcu_set()` 只能保证发布顺序，不能
单独保证旧对象 lifetime；`call_rcu()` 的 grace period 才补上这一半。

同理，若 event-loop 更新 handler 时立刻 free，正在遍历的线程可能继续访问旧 callback
或 opaque。当前 Aio 用 LockCnt 延迟删除，BH 用 consumer ownership；删掉这些生命周期
协议也会造成同类 UAF。

### 6.2 禁止更新或暂停访问：以能力和停顿换取简单性

另一种『没有 RCU』的正确方案是：VM 运行期间永不修改拓扑，或每次更新前暂停所有 vCPU、
停止所有 IOThread、清空 callback，再更新并恢复。这相当于把 grace period 实现成重量级
stop-the-world。它会影响 hotplug、memory listener、migration、设备启停等管理路径，且
暂停范围远大于『只等已持有旧指针的 reader』。

### 6.3 一个 mutex 包住 AddressSpace

正确性可以做到，但每一次 read/write/translate 都要竞争同一把锁。两个 MTTCG vCPU 原本
可同时访问各自 guest memory；mutex 会把它们串行化，设备 DMA 和 IOThread 也加入同一
队列。即使 uncontended lock 很快，它仍会写共享 lock word，造成 host CPU 间 cache-line
bouncing；而 AddressSpace lookup 是指令执行、页表访问和 DMA 的高频路径。

MemoryRegion callback 还可能重入 memory API，简单 non-recursive mutex 会自锁；改成
recursive mutex 虽避开自锁，也没有解决不同线程串行和 lock ordering。若 callback 再等待
另一个需要此锁/BQL 的线程，死锁面会扩大。

### 6.4 rwlock 比 mutex 好，但仍不等价

rwlock 允许 reader 并行，功能上可保护 lifetime，但：

- 普通集中计数的实现需要在获取、释放读锁时原子更新共享状态，以协调 writer；仅检查
  『当前没有 writer』不够，因为检查后 writer 可能进入。第 6.5 节分析这种共享写的成本。
- writer 必须等当前所有 reader，并且实现/调度策略不当时可被持续到来的 reader 饿死；
  RCU grace period 只关心开始等待前的 reader，新 reader 不延长本轮。
- updater 若持 BQL 再阻塞于 write lock，仍需严密证明 reader 不会为退出路径索取 BQL。
- 一把全局 rwlock 把原本无关的 AddressSpace、QHT、log 等 RCU consumer 耦合到同一锁；
  每对象一把锁又增加内存、初始化、销毁与 lock-order 管理成本。

所以 QEMU 官方文档称 read side 为 wait-free，并强调全系统可共用一个 RCU mechanism。
这不是说 RCU 在所有维度都免费：它把成本转移到了复制/发布、延迟释放、reader 注册、
memory ordering 和 grace-period 检测。

### 6.5 硬件成本：原子操作与 cache line 写竞争

原子性描述的是操作不可被观察为执行了一半，不意味着每次都要锁住总线。
以 x86 为例，对齐且宽度受架构保证的原子 load/store 可以使用普通 `mov`；
原子递增、CAS 等读改写通常需要取得目标 cache line 的独占写权限。即使指令带有
`LOCK` 前缀，对正常的、位于单个 cache line 内的可缓存内存操作，通常也通过缓存
一致性机制实现；跨 cache line 的 locked 操作或某些非缓存内存访问才可能触发 bus lock。
依据见 [Intel 架构文档](https://cdrdv2-public.intel.com/812380/252046-sdm-change-document.pdf)
和 [Linux bus lock 文档](https://docs.kernel.org/next/x86/buslock.html)。

以采用集中 reader 计数的普通 rwlock 为例，reader 虽然能并行读取业务数据，但进入和
退出时都要修改同一份锁状态。在不同 CPU 上运行时，这条 cache line 的写权限可能反复
转移，增加等待和缓存一致性通信：

```text
集中计数的 rwlock：
CPU 0 ── 原子增减 ──┐
CPU 1 ── 原子增减 ──┼── shared_reader_count 所在的同一 cache line
CPU 2 ── 原子增减 ──┘             写权限在 CPU 之间转移

QEMU RCU 的主要读侧访问：
CPU 0 ── 读取 generation ── 更新 reader_0.ctr
CPU 1 ── 读取 generation ── 更新 reader_1.ctr
CPU 2 ── 读取 generation ── 更新 reader_2.ctr
回收端 ── 等待 grace period 时扫描各 reader 的 ctr
```

共享 generation 在两次推进之间主要被读取，多个 CPU 可以保留其缓存副本；各 reader
则更新自己的 `ctr`，避免每次进入、退出都争写同一个计数器。这里的 CPU 编号只是示意，
QEMU 状态实际属于 thread/coroutine，线程可以迁移，并非固定的 per-CPU 槽位。

因此收益来自共享数据的访问方式变化：高频的集中争写变成分散更新，回收端再负责扫描和
等待。原子指令数量本身不足以判断性能。回收端读取 `ctr` 仍会带来一致性通信，reader
状态若落在同一 cache line 上也可能有 false sharing，内存屏障同样有成本；RCU 减少
这些竞争的集中程度，并不保证消除全部开销。实际加速幅度仍需结合负载测量。

### 6.6 RCU 不适合什么

- write-heavy、必须原地修改且 reader 必须看到字段间强一致性的结构，普通 mutex 往往更
  简单。
- RCU 不处理 writer-writer conflict；例如 MemoryRegion topology update 仍靠 BQL。
- reader 临界区不能无限长，否则旧对象与 callback 积压；QEMU 因此有 force-RCU notifier
  和 `drain_call_rcu()`。
- 从 RCU 临界区带出指针必须另取 ref；仅保存裸指针会在 unlock 后失去 lifetime 保证。

RCU 减少的是读写之间必须相互等待的范围，未必缩短 updater 自己持有 BQL 的时间。
实际收益取决于读写比例、临界区长度和更新成本，不能仅凭使用 RCU 就断言吞吐提升幅度。

## 7. mini-virt 运行时证据

以下为文首版本对应的调试记录，结论限定于该 source/binary 和所列执行路径。

### 7.1 调试方法

使用 mini-virt 调试，用 GDB 从 process 启动前设置断点：

```gdb
b call_rcu_thread
b flatview_destroy
b mttcg_cpu_thread_fn
b qemu/system/physmem.c:3434
run
```

### 7.2 一个 reclaimer、两个 vCPU

`call_rcu_thread()` 首次进入时只有 main 和新建线程：

```text
=== call_rcu OS thread entered ===
Id 1  LWP 14743  main
Id 2  LWP 14746  call_rcu_thread() at util/rcu.c:283

#0 call_rcu_thread()
#1 qemu_thread_start() at util/qemu-thread-posix.c:393
#2 start_thread()
#3 clone3()
```

第二个 `mttcg_cpu_thread_fn()` 进入时共有 4 个 host threads：main、LWP 14746、两个 MTTCG vCPU。

```text
PID    TID    COMMAND
15316  15316  qemu-system-aar
15316  15317  qemu-system-aar
15316  15318  CPU 0/TCG
15316  15319  CPU 1/TCG
```

RCU thread 的 Linux `comm` 在本次仍显示截断的 process name，而非 `call_rcu`：它由 ELF
constructor 创建，发生在 command-line `-name debug-threads=on` 生效之前。它的身份由
GDB 的 TID 14746 与 `call_rcu_thread()` stack 确认。mini-virt 没有额外配置 IOThread。

### 7.3 FlatView 确实由该线程回收，并持有 BQL

```text
=== FlatView reclamation callback ===
Current thread: LWP 14746
BQL held: 1

#0 flatview_destroy() at system/memory.c:294
#1 call_rcu_thread() at util/rcu.c:324
#2 qemu_thread_start()
#3 start_thread()
#4 clone3()
```

这把两个静态事实连了起来：`flatview_unref()` 在 refcount 到零时提交 callback；独立
thread 越过 grace period 后，在 BQL 内真正运行 `flatview_destroy()`。所以『独立线程只是
等待，但由 main thread free』与『callback 不持 BQL』都不符合当前实现。

### 7.4 AddressSpace read 的 RCU nesting depth 为 2

guest Linux 初始化 SMMUv3 command queue 时，GDB 停在 RCU guard 后一行：

```text
=== AddressSpace read inside RCU critical section ===
RCU nesting depth: 2
BQL held: 1

#0 address_space_read_full(address_space_memory, addr=0x41000000, len=16)
#1 address_space_rw()
#2 dma_memory_rw_relaxed()
#3 dma_memory_rw()
#4 dma_memory_read()
#5 queue_read() at hw/arm/smmuv3.c:114
#6 smmuv3_cmdq_consume() at hw/arm/smmuv3.c:1309
#7 smmu_writel() at hw/arm/smmuv3.c:1620
#8 smmu_write_mmio()
#9 memory_region_write_with_attrs_accessor()
```

depth 2 说明这次 AddressSpace API 进入时已经处于外层 RCU 临界区，memory core 的 guard
安全嵌套。`BQL held: 1` 是这次 SMMUv3 MMIO callback 的现场，不应推广为『所有
AddressSpace read 都持有 BQL』；IOThread 或 MTTCG 的 RAM fast path 可以在 BQL 外运行。
