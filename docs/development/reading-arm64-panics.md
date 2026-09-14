---
title: 从 ARM64 panic 反推根因
status: active
owner: runtime
last-verified: 2026-09-14
verified-against: git:3c8cc6fef828e1cdd78da54a179583d67bca7475
review-cycle: 90d
source-of-truth: code
---

# 从 ARM64 panic 反推根因

客户机 panic 给你的通常只有一行寄存器。本文记录如何把它变成一个确定的代码位置，
以及在这个仓库里反复奏效的几条手法。所有例子都来自真实排查，不是构造的。

## 一、先把寄存器行读懂

典型的一行：

```
Unhandled synchronous-el0 interrupt. SPSR: 60000004 PC: 21AC519 x30: 7FFF8534E8
SP: 208003D0FDF0 x0: 50000DB62AE9 ... x6: 50000DB62AE9 ... x9: 21AC519
ESR: 8A000000 FAR: 21AC519
```

### ESR：先看 EC 字段（bit 31:26）

`ESR >> 26` 就是异常类别。本仓库里高频出现的几个：

| EC | 含义 | 典型成因 |
| --- | --- | --- |
| `0x22` | PC 对齐错误 | 跳到了一个**带标签的 Lisp 对象地址**，不是代码地址 |
| `0x24` / `0x25` | 数据异常 | 读写了未映射/无权限的页 |
| `0x20` / `0x21` | 指令异常 | 取指时缺页 |

`ESR = 8A000000` → `0x8A000000 >> 26 = 0x22` → PC 对齐错误。

**这一步就能定性**：代码地址在 ARM64 上必然 4 字节对齐，而 `0x21AC519` 末位是 9。
Lisp 对象指针带低位标签（对象 = 9，cons = 1），所以"末位是 9 的 PC"等价于
**把一个对象当函数跳了过去**。不需要看任何源码就能得出这个结论。

数据异常时再看低 6 位的 DFSC：`0b0001xx` 是转换错误（页不存在），
`0b0011xx` 是权限错误。前者多半是缺页，后者多半是写只读页（快照 CoW）。

### SPSR：判断故障发生在什么上下文

- bit[3:0] 模式：`0` = EL0t，`4` = **EL1t**（普通 Lisp 线程，用 SP_EL0），
  `5` = **EL1h**（异常/wired 栈）。
- bit[9:6] = `D,A,I,F` 中断掩码。**任一置位就说明当时关着中断**。

`SPSR = 60000004` → EL1t、中断开着 → 普通线程态，可以放心地在这条路径上加日志。

`SPSR = 600003C5` → `0x3C5 & 0x3C0 = 0x3C0`，四个掩码全置 → 在
`safe-without-interrupts` 区间内。这时 `%page-fault-handler` **按设计拒绝服务**并报
`page-fault-no-irqs`，见[不可分配上下文](allocation-forbidden-contexts.md)。
结论直接变成"这条路径触碰了未驻留内存"，而不是"pager 有 bug"。

### FAR 与 PC

FAR 是出错的**地址**。数据异常时它是被访问的数据地址，取指异常时它等于 PC。
`FAR == PC` 且 EC=0x22，说明问题就是跳转目标本身。

## 二、用地址区间判断"这是什么东西"

这一步在本仓库特别有效，因为地址区间和对象种类强相关：

| 地址形态 | 含义 |
| --- | --- |
| `7FFF…` | **wired 区代码**（supervisor） |
| `8000…` | **可换页代码**（system/runtime，第四阶段会被换出） |
| `2080…` / `2000…` | 线程栈（前者普通栈，后者 wired 栈） |
| 七位左右的小地址，如 `11D8AF9`、`21AC519` | wired 区**对象**（线程、fref、定时器…） |
| `48000…` / `50000…` | CLOS/通用区对象 |

所以看到 `x6 = 50000DB62AE9`（通用区对象）而它的"入口点"是 `21AC519`
（wired 区对象），立刻就知道：**某个对象的入口点槽里存的是另一个对象的指针**。

再配合 Mezzano 的调用约定，能精确到指令：

- `x6` = 被调用的函数对象
- `x9` = 从函数对象里加载出来的入口点
- `x5` = 参数个数（fixnum 编码，即 `2 * n`）
- `x0`–`x4` = 参数

`x9 == FAR == PC` 且 `x9` 是从 `x6` 的槽 0 读出来的 → 调用序列本身没错，
**是 `x6` 这个对象的槽 0 被写坏了，或者 `x6` 根本不是函数**。

## 三、栈回溯怎么读

回溯里同时有 wired（`7FFF…`）和可换页（`8000…`）代码地址。看**最靠近故障点的
那个有名字的帧**，它通常就是现场：

```
20000061FF40 80002B4814 (LAMBDA IN (SETF FUNCTION-REFERENCE-FUNCTION))
20000061FFE0 7FFF9268E0 %CALL-ON-WIRED-STACK-WITHOUT-INTERRUPTS
20800120C2F0 800027ABEC (SETF FUNCTION-REFERENCE-FUNCTION)
```

注意栈指针从 `2080…`（普通栈）跳到 `2000…`（wired 栈）——这是
`%call-on-wired-stack-without-interrupts` 的边界。**边界之上的所有帧都在关中断
上下文里**，必须只碰已驻留内存。这一眼就把问题从"为什么缺页"变成
"这个 thunk 触碰了什么可换页的东西"。

## 四、方法论：这些手法比读源码更快

### 1. 否定结论同样是证据，而且往往更值钱

排查 compositor 的 PC 对齐错误时，我在**三个**写入入口点的站点都加了硬检查
（闭包分配、funcallable instance 分配、`(setf funcallable-instance-function)`）。
下一轮**一个都没触发**。

这条否定结论一次性排除了"入口点在写入时被写坏"的全部可能，把方向从 GC / `change-class`
掉转到"传进来的根本不是函数"——而后者三分钟就查到了：`make-thread` 的契约是
`(or function symbol)`，但线程入口改用了直调原语，丢掉了 `funcall` 的符号强制转换。

**推论**：设计探针时要让"没打印"也是一个明确结论，而不只是"还没走到"。

### 2. 先修诊断路径，再修缺陷

`%allocate-funcallable-instance` 里**本来就有**一个能抓到这个问题的对齐检查，
但它被 `*cold-boot-in-progress*` 门控——第四阶段永远不会运行，而那正是唯一需要它的时候。

在诊断路径本身有缺陷时，你读到的每一条错误信息都可能是假的。

### 3. 区分"我的探针造成的故障"与"真实故障"

这类事故在本次排查中出现过多次：

- 在关中断区间用 `debug-print-line`（它经分配器格式化）→ 栈溢出
- 给 `safe-without-interrupts` 补捕获列表 → thunk 被挪到未驻留的页 → `page-fault-no-irqs`
- 探针字符串重名（函数入口和循环体都叫 `"res: entry"`）→ 日志无法区分递归与循环

**规则**：受限上下文里只用 `debug-uart-boot-line` / `debug-uart-boot-hex-line`（零分配，
直写 UART）；探针字符串必须唯一；循环里的探针必须有计数上限。

### 4. 打指针，不要打对象

`debug-print-line` 打印对象会走打印器，可能再次触发故障。
`(sys.int::lisp-object-address x)` + `debug-uart-boot-hex-line` 永远安全。

定位"循环不终止"时，决定性的一轮探针是这样的——它同时给出了迭代器有没有前进、
以及 cdr 是不是 NIL：

```lisp
(do ((itr *hosts* (cdr itr)) (n 0 (1+ n)))
    ((or (null itr) (> n 8)) (debug-print-line "hw: walk-end n " n))
  (debug-print-line "hw: itr " (sys.int::lisp-object-address itr)
                    " cdr " (sys.int::lisp-object-address (cdr itr))))
```

输出 `hw: itr <同一地址> cdr 400009` 重复 170 万次，一次性证明了
"cdr 算对了（400009 就是 NIL），但写回迭代器没生效"——问题不在 `assoc`、
不在 `string-equal`、也不是环形表，而是**循环变量的赋值被丢弃了**。

### 5. 把目标代码搬到宿主上跑

目标代码大多是普通 Common Lisp。把可疑函数连同它依赖的宏抽出来，在宿主 SBCL 里
直接求值，比在客户机上迭代快两个数量级。

`restart-case` 展开成 `NIL` 就是这样定案的——抽出宏定义，`macroexpand-1`，
输出 `EXPANSION => NIL`。整个过程不到一分钟，且完全不依赖客户机。

注意宿主的包锁：CL 标准符号要改名（`restart-case` → `my-restart-case`）才能重定义。

### 6. 交叉编译单个函数，导出汇编

怀疑代码生成时，不要猜：

```lisp
(cold-generator:set-up-cross-compiler :architecture :arm64)
(let ((mezzano.compiler::*trace-asm* t)
      (mezzano.compiler::*target-architecture* :arm64))
  (mezzano.compiler::cross-compile-file "/tmp/probe.lisp"
                                        :output-file "/tmp/probe.llf"))
```

必须在 `Lambda64/` 目录下运行（源文件路径是相对的），且必须绑定
`*target-architecture*`，否则报未绑定变量。

**关键技巧是做对照**：写两个只差一处的变体，比较生成的指令。
定位 NLX/SSA 那个缺陷时，对照组是"兄弟绑定的初值形式会不会抛错展开"：

```
无展开：  ADDS :X0 :X0 2            ← 直接累加活值，正确
有展开：  ORR :X0 :XZR :XZR         ← 每次迭代把变量重新物化成初值
          ADDS :X0 :X0 2
```

一眼就能看出赋值被常量折叠掉了。单看一份汇编是看不出"不对"的，有了对照才有判据。

### 7. 用宿主侧证据验证客户机行为

网络问题用 `-object filter-dump,id=pcap0,netdev=vmnic,file=x.pcap` 抓包。

"一个包都没发出"这个事实，一次性把"IRQ 投递数为 0"从**原因**降级为**结果**——
没发包自然没有回包。省掉了整条在中断控制器上找问题的弯路。

## 五、一个完整的例子

**现象**：`ESR 8A000000  PC/x9 21AC519  x0=x6 50000DB62AE9  SPSR 60000004`

1. `0x8A000000 >> 26 = 0x22` → PC 对齐错误 → 跳到了对象而非代码。
2. `SPSR` 模式 4、掩码全零 → 普通线程上下文，不是关中断路径。
3. `x9` 是入口点、`x6` 是函数对象，`x9` 取自 `x6` 槽 0 → 调用序列正确。
4. `x6` 在通用区、`x9` 指向 wired 区对象 → 槽 0 存的是对象指针。
5. 在三个写入站点加硬检查 → **全部未触发** → 不是写坏的。
6. 那就是 `x6` 本身不是函数 → 查 `make-thread` 契约 → `(or function symbol)`。
7. 查线程入口 → 直调 `%call-function-noargs`（`ldr x9, [x6, #slot0]; blr x9`），
   不做符号强制转换 → 传符号进来读到的是符号的第一个槽。
8. 全树 9 处 `(make-thread 'some-symbol ...)` → 契约没错，实现错了。

第 5 步的否定结论是整条链的转折点。

## 六、契约测试要锚定语义，不要锚定文本

本次排查修了 6 处因源码**正确演进**而误报的契约测试：`%%gc` 的签名、一个包前缀、
CAS 表达式的缩进、一个文件位置变更、`:sparse t`、`:stride 2`。

每次都要先判断"是代码错了，还是测试锚偏了"，而这个判断本身很花时间。更糟的是，
逐字符锚点会制造一种压力：为了让测试通过而放弃正确的改法。

写契约测试时：

- 锚定**要守的性质**（"入口点取自 VALUE 而非 trampoline"），而不是当前写法
- 正则容忍等价形式（可选包前缀、关键字与位置两种调用）
- 在测试里写明**这条约束为什么存在**，以及违反后的具体症状
- 变异检测要针对性质，而不是针对某个字符串的存在

## 相关文档

- [不可分配上下文](allocation-forbidden-contexts.md)：关中断/世界停止等受限上下文的完整清单
- [四阶段构建与依赖加载](../architecture/four-stage-build-and-dependencies.md)：判断故障属于哪个阶段
