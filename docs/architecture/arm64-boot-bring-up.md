---
title: ARM64 引导修复记录
status: active
owner: runtime
last-verified: 2026-09-14
verified-against: git:275bc64ce278e99b8a164fccb7ec5d0b72eb09cc
review-cycle: 180d
source-of-truth: code
---

# ARM64 引导修复记录

本文记录把 ARM64 目标从「`mezzano: Starting system.` 之后立即死亡」修到
**完整进入桌面**所定位的 21 个根因。

按层次组织，每条给出**症状**、**根因**与**为何难找**。最后一节归纳三个反复出现的
模式——那部分比单个缺陷更值得读。

修复分布在 6 个提交（`ee8ccca0`…`275bc64c`），每个根因都有对应的回归测试或文档。

## 一、按层次的根因

### 冷生成器

**`(setf …)` 函数定义被静默丢弃**（影响面最大）

- 症状：PNG 解码报 `Undefined function (SETF %OBJECT-REF-T)`，经 `LOAD-PNG` 的
  `ignore-errors` 转成笼统的 "Unable to load"。
- 根因：`environment-name-fref-table` 是 **weak-key** 表。函数名要么是符号，要么是
  `(setf 符号)` **列表**；列表名在每个调用点都是新构造的 cons，表外无引用，宿主 GC
  一跑条目就消失。符号名因符号全局可达而幸存。
- 后果：37 个 builtin setf wrapper、`(setf %object-ref-t)`、16 个 `%%object-ref-*`
  原语的 setf，**全部以未绑定状态进入镜像**。
- 为何难找：损坏是**精确的一半**——读取函数全在，写入函数全无。这个「整齐」本身是
  最强线索，但要先想到去对比读写两侧。宿主上四行代码即可复现：weak-key `equal` 表
  在一次 GC 后丢掉列表键、保留符号键。

### 编译器

**NLX 目标边被从 CFG 中移除 → φ 节点缺失 → 循环赋值被丢弃**

- 症状：`resolve-address` 中 `assoc` 在单元素表上不终止。
- 根因：`build-cfg` 与 `successors` 都不再报告 `begin-nlx` 的目标块。SSA 构造与
  `dynamic-contours` 走这张图，NLX 落地块因此没有前驱，绑定的活跃范围传播不进去，
  φ 放置拒绝了所有经由该块可达的块。ARM64 于是把循环累加器折叠回初值：
  `ORR :X0 :XZR :XZR` / `ADDS :X0 :X0 2`。
- 为何难找：只有**真正发生过展开**的 `handler-case` 之后才触发。传 IP 字面量的调用
  第一步就成功，从不走展开路径，所以只有域名解析会挂。
- 相关：TF-WI-0029 的第 3 步（NLX 感知的后继关系接入支配与 φ 放置）**从未实现**，
  移除这些边是半途而废的重构。再次移除的前置条件见该规格文档。

**`(dcas %memref-t)` 生成了不可调用的 wrapper 名**

- 症状：`DCAS fell through ECASE form`，冷启动早期。
- 根因：`define-builtin` 默认 `:has-wrapper t`，但 `valid-function-name-p` 只承认
  `(setf x)` 和 `(cas x)`。x86-64 用符号名 builtin，没有这个问题。
- 为何难找：**被上一条掩盖**——弱表把所有列表名 fref 一并吞掉，包括这个非法的。

### 语言核心

**`restart-case` 展开成 `NIL`**

- 症状：网络 dispatch 上下文的管理线程静默消失，整个上下文失效。
- 根因：一次重写引入三处独立缺陷——生成展开式的 `let*` 落在收集子句的 `dolist`
  体内（宏返回 `dolist` 的 `NIL`）；`(let ((restart-result (catch …)))` 少一个右
  括号，`if` 变成第二个绑定说明符；`throw` 送出 `(label 参数表)` 而消费端用
  `(rest …)` 取参数，多包一层。
- 后果：**全系统每一个 `restart-case` / `with-simple-restart` 的体都是死代码**。
- 为何难找：线程走到 `with-simple-restart` 处发现只有一个 `NIL`，正常返回、干净退
  出，无错误无 panic。既有测试是纯文本 grep 契约，从不求值宏。

### 运行时 / GC / CLOS

**`supersede-instance` 的 CAS 成功判定颠倒**

- 症状：ASDF 报 `Invalid initargs … (PROTO-SYSTEM) valid: ()`。
- 根因：`cas` 返回 place 的**旧值**而非成功标志。当布尔用时逻辑正好反过来；而「已过
  时实例」分支的槽位按定义非 nil，`nil` 期望值的 CAS 永不可能成功，于是每次都走
  「失败即成功」的错误路径。`change-class` 第二次调用完全空转，ASDF 的
  `reset-system-class` 依赖连做两次转换。

**funcallable instance 入口点用装箱访问器转发**

- 症状：Compositor 线程 PC 对齐错误（ESR EC `0x22`），入口点是带标签的对象地址。
- 根因：GC 的过时实例转发用 `%object-ref-t` 复制入口点。入口点是**原始代码地址**，
  当 Lisp 值交给正在运行的收集器，会被当指针扫描、转发并写回。
- 为何难找：只有修好上一条之后，这条路径才真正开始被执行。

### supervisor / 驱动

- **`virtqueue` 的 `last-seen-used` 无 initform**，位置参数构造器只覆盖 6 个几何
  槽位，该计数器默认为 `NIL`。`(eql used-idx NIL)` 永不成立，接收循环不走 `return`
  而落进取包分支执行 `(rem NIL size)`，NIC worker 当场死亡、一个帧都发不出去。
- **线程入口丢失符号强制转换**。`make-thread` 的契约是 `(or function symbol)`，全树
  9 处这样调用，但入口改用了 `%call-function-noargs`——一段只有
  `ldr x9,[x6,#slot0]` + `blr x9` 的手写汇编，传符号进去就跳到它的第一个槽。
- **GPU / 输入设备的认领时机**。两者由内建 case 分发、不进 `*virtio-drivers*`，而
  `virtio-late-probe` 只遍历注册表，被推迟的设备永远等不到处理器。改由 IPL 显式认
  领后又发现必须**早于** `input-drivers-virtio.lisp`——该文件在**加载时**枚举
  `*virtio-input-devices*`。它同时注册了 boot hook，所以只影响首次引导。

### 受限上下文的分配（4 次）

关键字 lambda list 会在通用区**物化参数向量**。在关中断区间、世界停止期间或持有
VM 写锁时，这一次分配就是致命的。四次撞上，每次位置参数入口都已存在或唾手可得：

| 位置 | 触发条件 |
| --- | --- |
| `%release-vm-page` | 会话早期 |
| `make-virtio-driver` | `safe-without-interrupts` 内，潜伏至镜像布局变化 |
| `room` 的 `bsearch` | `call-with-world-stopped` 内 → `Going PA with world stopped!` |
| `snapshot` 的 `map-ptes` | 持 VM 写锁 → `Page fault … while holding *VM-LOCK*` |

**分配器锁纪律**同属此类但更严重：「停世界方不得取锁、也不得进伪原子区」这条规则原本
只写在 7 处取锁点中的 1 处。快照走到任意其余一处即死锁——活锁看门狗报
`World stopper … wait #<Mutex Allocator :Owner #<Thread Desktop>>`。现已收口为
`with-allocator-lock` 宏，并由契约测试断言宏之外不得裸调锁。

### 网络 / 文件系统

- **重连路径只认 `connection-error`**。文件服务有 60 秒空闲超时；已关闭的流会让
  `read-sequence` 从 `frob-input-stream` 抛 `stream-error`，响应未达则是
  `end-of-file`，两者都不是 TCP 条件类。另外零长度的「探活」读取**不接触 socket**，
  察觉不到对端 FIN。
- **DHCP 退避条件倒置**（`(<= 16 pause)` 应为 `(<= pause 16)`），首次失败即睡 5 分钟。
- **`most-positive-fixnum` 目标侧未定义**，只存在于 cross-boot。ASDF 的
  `#.most-positive-fixnum` 在读取期求值失败。现由 `+n-fixnum-bits+` 推导，避免两处漂移。
- **`dispatch-at` 不存在**（应为 `dispatch-after`），且 `dispatch-after` 未把 `queue`
  传给 `make-source`，默认目标读 `*local-context*`——在 IP 线程里是 NIL。

### 资源配置

- **主线程栈 1 MB 不足**。它要编译整棵依赖树，而编译器递归遍历引用常量；babel 的
  `jpn-table.lisp` 单个列表约 8000 元素，正好撞穿。已提至 16 MB——栈是
  `+block-map-zero-fill+` 映射，只占地址空间不占物理内存。
- **关中断区间读取可换页对象**。`(setf function-reference-function)` 预解析了 fref 的
  CoW 映射，但没预解析 `value`——后者同样住在可换页函数区。只在换页压力下出现。

## 二、三个反复出现的模式

### 1. 约束以「局部写法」存在就必然被遗漏

关键字分配隐患 4 次、停世界锁规则 7 处只写 1 处、弱表对符号安全对列表致命。每次都是
「某处做对了，同类站点漏了」。

**对策**：把约束变成机制。`with-allocator-lock` 加上「宏之外不得裸调锁」的契约测试，
比在 7 处各写一遍注释可靠。

### 2. 否定证据常常比肯定证据值钱

排查 PC 对齐错误时，在三个写入入口点的站点都加了硬检查，下一轮**一个都没触发**。
这条否定结论一次性排除了「写入时被写坏」，把方向扭向「传进来的根本不是函数」。

**对策**：设计探针时要让「没打印」也是明确结论，而不只是「还没走到」。

### 3. 契约测试要锚定语义，不要锚定文本

6 处逐字符锚点因源码**正确演进**而误报。更糟的是，逐字符锚点会制造压力——为了让测试
通过而放弃正确的改法。这不是假设：`test-compiler-ssa-nlx-cfg-boundary.sh` 断言 NLX 边
**不得存在**，把一个半成品重构固化成了契约，而那正是循环赋值被丢弃的根因。

## 三、验证与遗留

**验证**：干净镜像（无任何调试探针），62k 行串口输出，0 panic，冷启动与收尾两次快照
均完成，桌面可见、鼠标可用，运行中系统经 SWANK 应答 24 个线程。宿主测试套件全绿。

**遗留**（见[技术债登记](../modernization/debt-register.md)）：

- D020 受限上下文的关键字分配，目前只靠文档约束
- D021 `ext4.lisp` 的 112 槽位 `defstruct` 编译耗时 1209 秒
- D022 逐字符锚点的契约测试
- D023 TF-WI-0029 第 3 步未实现
- D024 virtio-gpu 每帧一次全裁剪区的同步传输+刷新

## 相关文档

- [从 ARM64 panic 反推根因](../development/reading-arm64-panics.md)
- [不可分配上下文](../development/allocation-forbidden-contexts.md)
- [四阶段构建与依赖加载](four-stage-build-and-dependencies.md)
