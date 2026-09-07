---
title: ARM64 冷启动动态排障记录
status: active
owner: build-and-test
last-verified: 2026-09-04
verified-against: git:working-tree
review-cycle: 30d
source-of-truth: dynamic-trace
---

# ARM64 冷启动动态排障记录

本文记录 2026-09-04 对 `lambda64.image` 的动态分析结果。它是当前排障快照，不是
“启动成功”的证明；每次重新生成镜像后都应更新提交、镜像摘要和串口证据。

## 当前进度

- `make test-image` 成功，镜像约 5 GiB，manifest 与提交 `18df4cd8` 对齐。
- ARM64 QEMU（TCG，2 GiB guest memory，4 vCPU）能够完成 kboot 加载，串口到达
  `Loading 138226 wired pages... complete` 和 `mezzano: Starting system...`。
- 45 秒至 600 秒的启动烟测尚未出现 Guest 测试完成标记，也没有 fatal/panic 标记；
  因此当前结论是“启动后仍未完成”，不能称为通过。此时尚未证明是死锁还是极慢的
  初始化循环。

## 动态调用链证据

通过 QEMU GDB RSP 在真实函数地址处设置软件断点，并在命中后执行单步越过断点，
避免把断点停留误判成死循环。命中 `%TRUNCATE` 时，初始线程（thread/object
`0x478429`）的调用链稳定为：

```text
UPDATE-FREELIST-CARD-OFFSETS
  -> %FREELIST-ALLOCATE-INTERNAL
  -> %ALLOCATE-FROM-FREELIST-AREA
  -> %ALLOCATE-FROM-WIRED-AREA-UNLOCKED
  -> %ALLOCATE-FROM-WIRED-AREA-1
  -> %ALLOCATE-FROM-WIRED-AREA
  -> %ALLOCATE-OBJECT
  -> %ALLOCATE-INSTANCE
```

对应源码为 `Lambda64/runtime/allocate.lisp:132-142`。循环以
`sys.int::+card-size+`（当前值 `0x2000`）为步长，为新 freelist 区间的每个卡边界
写入反向偏移。动态寄存器显示卡地址从 `0x2338000` 持续递增，而区间起点为
`0x2337760`；这解释了为何启动阶段会长时间反复调用 `%TRUNCATE`。

早期另一组 `%TRUNCATE` 命中来自
`DEBUG-LOG-BUFFER-WRITE-BYTE-1` 中的环形缓冲区 `rem`，调用链是
`FDT-RESOLVE-PROP-PATH -> DEBUG-WRITE-STRING -> DEBUG-LOG-BUFFER-WRITE-BYTE`。
它属于正常日志写入，不是当前主要瓶颈，不能把这组命中与 freelist 更新混为一谈。

## 仍需确认的问题

1. `UPDATE-FREELIST-CARD-OFFSETS` 的 `end` 实际范围是多少，循环预计迭代多少个卡。
2. 这次大范围更新是否是冷启动必须的一次性工作，还是由错误的 freelist 长度、
   地址范围或重复扩容触发。
3. 在不设置每次 `%TRUNCATE` 断点的采样运行中，卡地址是否持续前进并最终离开该
   函数；断点单步会显著放大耗时，不能据此估计真实速度。

## 排障经验与护栏

- `lambda64.map` 中的 `DEFGLOBAL` 行描述的是符号，不是全局值槽；读取全局值必须
  使用 `lambda64.symbol-table` 的 cell 地址，再按符号值单元布局读取 slot 2。直接
  读取 map 地址会得到误导性的垃圾值。
- QEMU RSP 的软件断点命中后 PC 会停在断点地址。必须临时删除断点、单步、再安装，
  否则会把同一条指令无限重复执行，形成假死循环。
- `qemu-system-aarch64` 的 TCG/HVF 启动时间不能直接与断点跟踪时间比较；动态跟踪
  只用于确认调用链、参数和状态，性能结论必须用无断点采样复核。
- 只有串口 oracle 的完成标记、退出码和结果目录中的 manifest 才能证明集成通过；
  `Starting system...` 本身不是成功标记。

## 下一步

优先在无断点运行中采样 `UPDATE-FREELIST-CARD-OFFSETS` 的入口/返回和 freelist
头部，计算真实 `end-start` 与进度；若范围异常，再修正长度来源并只提交一个最小批次。
若范围合理，则应先优化或分段这次卡表初始化，再重新生成镜像并运行快速启动烟测。

## 2026-09-07：临时 store freelist 的保留块不变量

本轮动态断点在 `STORE-ALLOC` 命中时观察到返回块号为 `0`，调用者是
`ALLOCATE-NEW-BLOCK-FOR-VIRTUAL-ADDRESS`。根因不是物理页元数据分配，而是冷启动
重放序列化 freelist 之前，临时 freelist 从块 0 开始；而冷生成器在
`*store-bump* = #x3000` 后才分配 store，块 0、1、2 分别属于镜像头、BML4 和
序列化 freelist，不能作为 backing store。

修复保持临时范围 `[0,N)` 的连续形状（这样首个序列化 USED 区间可整体重放），但在
`*store-freelist-bootstrap-p*` 期间从范围高端分配 backing 块，并拒绝落入保留前缀。
`initialize-store-freelist` 将该动态绑定覆盖到整个重放过程；元数据页本身仍通过
位置参数物理分配，避免 pager/关键字参数在冷路径分配临时对象。

验证：重建镜像成功；120 秒 ARM64 TCG 诊断烟测不再出现
`Tried to insert bad range` 或 `Mapping new wired page ... not present` panic，
但仍停在 `mezzano: Starting system...` 且超时，说明下一个问题位于启动后调度/等待
路径，尚未满足正向 oracle。
