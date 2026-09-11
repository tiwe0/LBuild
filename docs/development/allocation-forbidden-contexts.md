---
title: 不可分配上下文
status: active
owner: runtime
last-verified: 2026-09-11
verified-against: git:1f07257d782b742bac5c53a4bf1d90446f83c9aa
review-cycle: 90d
source-of-truth: code
---

# 不可分配上下文

在 supervisor 的若干上下文里，分配内存不是性能问题，而是**致命错误**。本文列出这些上下文、
分配悄悄溜进来的四条途径、安全替代，以及树内已有的机器检查。

这些约束在源码里看不出来：Lisp 的分配是隐式的，编译器不会提醒你某个调用会分配。
本文记录的每一条都对应至少一次实际故障。

## 一、哪些上下文禁止分配

| 上下文 | 如何判定 | 违反后的症状 |
| --- | --- | --- |
| 持有 `*vm-lock*` 写锁 | `rw-lock-write-held-p` | 缺页无法服务——pager 需要同一把锁。表现为**全部线程睡死、宿主 CPU 接近 0%**，无任何输出 |
| 收集器持有世界 | `sys.int::*gc-in-progress*` | `Allocating during GC!` |
| IRQ 屏蔽 | wired 栈、`%call-on-wired-stack-without-interrupts`、中断处理器内 | `page-fault-no-irqs`，`%page-fault-handler` 按设计拒绝服务，不可恢复 |
| 持有 `*allocator-lock*` | `mutex-held-p` | `Recursive locking detected on Allocator` |
| 伪原子区间 | `*pseudo-atomic*` | 世界停止器被阻塞；`acquire-mutex` 会显式 panic |

两个容易被忽略的推论：

- **TLAB 快路径不检查 `*gc-in-progress*`**。它只做指针碰撞，所以在 GC 窗口内的分配
  **不会**触发 `Allocating during GC!` 守卫，而是直接写进已解除映射的内存并缺页。
  `Lambda64/system/gc.lisp` 中 `fixup-tlabs` 必须紧贴 `gc-cycle` 之后调用，中间不得有
  任何可能分配的代码（包括浮点装箱）。
- **快照把整个函数区和 general 区标成只读 + CoW**（见
  `Lambda64/supervisor/arm64/snapshot.lisp`）。快照之后，对这些页的**第一次写**是一次
  CoW 缺页。若这次写发生在 IRQ 屏蔽区间内，系统直接死亡。

## 二、分配从哪里偷偷进来

### 1. 关键字 lambda list 会物化参数向量

```lisp
(defun release-vm-page (frame &key allow-wired stackp) ...)   ; 调用时在 general 区分配
```

**修法**：提供 `%` 前缀的位置参数入口，内部路径直调，关键字版本仅作为外部兼容包装。
树内实例：`Lambda64/supervisor/pager.lisp` 的 `%release-vm-page`、`%make-pte`。

### 2. `safe-without-interrupts` 捕获列表不全 → 堆闭包

```lisp
(let ((buf-data (car buf)))
  (safe-without-interrupts (buf)        ; buf-data 未列出
    ... (aref buf-data i) ...))         ; 成为自由变量 → 编译器堆分配闭包环境
```

**修法**：把闭包体引用的**每一个**外部变量都列进捕获列表。

**但要注意**：修改这类 thunk 本身是有风险的。补齐捕获会改变函数布局，可能把 thunk 挪到
函数区另一个未驻留的页上；而它是在 IRQ 屏蔽的 wired 栈上被调用的，于是换来一个
`page-fault-no-irqs`。**加固最受限的那条路径，本身就是一次不受限的操作。**
优先在调用点消除分配，而不是去改那条路径。

### 3. `debug-print-line` 经分配器格式化

`debug-print-line` → `debug-print-line-1` → `debug-flush-buffer` → `make-simple-vector`。
这是本次排查中最高频的违规来源，因为"加一行日志"看起来人畜无害。

**修法**：改用 `debug-uart-boot-line` / `debug-uart-boot-hex-line`（原始 UART，零分配）。

`Lambda64/supervisor/debug.lisp` 中 `panic-printing-p` 已覆盖 panic 与 GC 两种情形，
会自动切换到不缓冲直写路径。**不要**把该谓词扩展到"持有 VM 锁"——它会被
`debug-write-char` 在中断上下文调用，多出来的函数调用会在未驻留的函数页上缺页。

### 4. 浮点与 bignum 装箱

`(/ a (float b))`、`(incf *gc-time* seconds)` 都会分配。受限窗口内只用定点算术，
把统计与格式化移到窗口之外。

## 三、树内已有的机器检查

这些断言把"必然静默死锁"的错误变成了启动即报的错误，请勿删除：

| 位置 | 检查 |
| --- | --- |
| `Lambda64/supervisor/pager.lisp` | 持有 `*vm-lock*` 写锁的线程缺页时立即 panic，打印地址与完整栈 |
| `Lambda64/supervisor/sync.lisp` | `:unlocked` 状态必须蕴含 `owner` 为空；慢路径返回前校验所有权确实已移交 |
| `Lambda64/supervisor/thread.lisp` | 调度器活锁看门狗；ARM64 恢复 SP 不得落在 per-CPU wired 栈上 |
| `Lambda64/system/gc.lisp` | `*gc-debug-metadata*` 校验每一帧的 GC 元数据自洽 |

## 四、非机器检查的契约

以下约束只靠注释维持，改动相关属性前必须确认：

- **`:supervisor` 优先级意味着 GC 不扫描该线程的栈**。`scavengable-thread-p` 依赖
  "supervisor 线程只持有 wired 对象指针"这一契约。任何运行普通 Lisp 代码的线程都**不能**
  标为 `:supervisor`，否则它栈上的 general 区指针会在第一次 GC 后全部悬空。
  `Lambda64/supervisor/entry.lisp` 中主线程的优先级注释记录了这一点。
- **手写 LAP 函数的 `:no-frame` 声明与 `blr` 不相容**。`blr` 会覆盖 x30，声明 `:no-frame`
  等于告诉收集器"返回地址仍在 x30"。需要建立真实栈帧，见
  `Lambda64/supervisor/arm64/thread.lisp` 中 `%call-function-noargs`。
- **交叉编译期存在多个 `cas` 宏定义**（`Lambda64/compiler/package.lisp` 的 bootstrap
  展开、cross-compile 的 stub、`Lambda64/system/cas.lisp` 的实现）。bootstrap 展开必须
  是语义正确的比较-交换，否则一旦漏进目标代码，**每次 CAS 都会报告成功**，所有同步原语失效。

## 五、有效的调试手法

- **交叉编译单个探针函数并导出汇编**：宿主端加载 `:lispos`、
  `cold-generator:set-up-cross-compiler`、绑定 `mezzano.compiler::*trace-asm*` 为 `:full`，
  再 `cross-compile-file` 一个几行的文件。六十秒即可确认"这条 Lisp 到底生成成什么指令"。
- **与宿主汇编器对编码**：`as -arch arm64` 汇编同一条指令再 `otool -tvVj` 反汇编，
  与 `Lambda64/compiler/lap-arm64.lisp` 的输出逐字节比对。
- **先修诊断路径，再修缺陷**。本次排查中多个根因是在 panic 报告器、活锁看门狗和
  上述断言就位之后才第一次变得可见的。在诊断路径自身有缺陷时，读到的每一条错误信息都可能是假的。
- **区分"我的探针造成的故障"与"真实故障"**。原始 UART 之外的任何观测手段，
  在受限上下文里都可能自己就是故障源。
