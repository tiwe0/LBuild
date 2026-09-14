<div align="center">

# Lambda64

**一个完全用 Common Lisp 写成的操作系统 —— 内核、驱动、编译器、图形界面。**

[![CI](https://github.com/tiwe0/LBuild/actions/workflows/ci.yml/badge.svg)](https://github.com/tiwe0/LBuild/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](#许可证)
[![Language: Common Lisp](https://img.shields.io/badge/language-Common%20Lisp-lightgrey.svg)](https://common-lisp.net/)
[![Target: AArch64](https://img.shields.io/badge/target-AArch64-success.svg)](#为什么选-arm64)

[English](README.md) · **简体中文**

</div>

---

Lambda64 是一个从零构建的操作系统,它的每一层 —— supervisor、设备驱动、内存管理、
编译器、窗口系统 —— 都是 Common Lisp。底下没有 C 运行时:334 个 Lisp 源文件,
`.c` 文件一个也没有。唯一的非 Lisp 组件是把控制权交给映像的 KBoot 引导垫片。

它是 [Mezzano](https://github.com/froggey/Mezzano) 的二次开发,以 **AArch64 为主要
目标**重新构建,并在该平台上跑通了完整的图形桌面。

因为编译器本身就在运行的系统里,Lambda64 可以在不重启的前提下改写、重新编译并
重新载入自己的任何部分 —— 这正是我们把它作为 **AI 原生操作系统**基座的原因,详见
[为什么选 Lisp](#为什么选-lisp)。

## 系统特性

| | |
| --- | --- |
| **内核** | 纯 Common Lisp supervisor:分页、调度、SMP、中断 |
| **内存** | 分代复制式 GC,新生代/老年代各自半空间 |
| **编译器** | 自举、基于 SSA,具备 AArch64 与 x86-64 后端 |
| **语言** | 完整 Common Lisp:CLOS 与 MOP、条件与重启、宏、reader、`format` |
| **持久化** | 映像快照 —— 整个运行中的系统写入磁盘,重启后从停下的地方继续 |
| **图形** | 合成器、窗口管理、字体渲染、AArch64 SIMD 位块传输 |
| **网络** | Ethernet、ARP、IP、TCP、UDP、DHCP、DNS、HTTP |
| **文件系统** | ext4、FAT32、本地、远程、HTTP |
| **驱动** | virtio 块/网络/GPU/输入,USB EHCI 与 HID,Intel GMA 与 HDA |
| **在线开发** | SWANK —— 用 SLIME 连上运行中的系统就地修改 |

### 应用

REPL(基础版与增强版)、**med** 编辑器、文件管理器、图片查看器、IRC 客户端、
telnet 客户端、Mandelbrot 浏览器、内存监视器、系统检视器(`peek`)、事件探针、
设置面板 —— 全部运行在合成器之上。仓库内含
[McCLIM](https://github.com/froggey/McCLIM),可用于构建更多应用。

## 相对 Mezzano 的改进

最重要的一项是 **AArch64 从引导不起来到进入可用桌面**。此外分为八个方面:

<details open>
<summary><b>引导与 bring-up(AArch64)</b></summary>

- 修复 21 个根因,横跨冷生成器、编译器、运行时、GC、supervisor、驱动与网络各层
- 加固冷分页 bootstrap:等待队列先于中断建立、分页建立期间即服务 pager、分页发现
  前启用调度、存储空闲链与 pager 定序
- 正确的 EL1h 异常返回;线程保持在 `SP_EL0` / EL1t 栈模式
- 通用定时器推迟到时间子系统初始化,改用直接寄存器写入,并保护早期中断
- 开中断时机排在调度器就绪之后
- 16 MB 主线程栈,已发布函数预先触页

</details>

<details>
<summary><b>编译器与后端</b></summary>

- SSA 正确性:非局部退出的作用域轮廓纳入 CFG 建模、进入 SSA 前强制拆分关键边、统一支配块编号
- AArch64 与 x86 均把 NLX 跳转表作为 trailer 发射
- AArch64:128 位 DCAS 下降、指针 CAS、字面量池载入宽度解码、可编码立即数偏移、
  可回绕逻辑掩码、大参数个数检查、GC 安全的寄存器交换、保留 GC scratch 寄存器、
  SIMD 溢出对齐、`tbz`/`tbnz` 反汇编
- x86:紧凑栈布局、`push imm8` 短形式、反向标量 SSE 移动、字节谓词临时量、浮点相等
- 表示分析:修正 `ub64` 过度提升、保留不相交整数类型交集、精确标量复短浮点提升、
  装箱单浮点就地构造
- 调用规范化保留 debug value;不可达调用直接终止而非发射

</details>

<details>
<summary><b>冷生成器与映像序列化</b></summary>

- 修复所有 `(SETF ...)` 定义丢失的问题 —— 弱键表持有的是每次新 cons 的列表名
- 确定性根遍历;对象初始化走工作队列
- 保留结构槽 initfunction、类元数据与源码位置
- 冷字符串支持宽字符、数组秩校验、未装箱槽位打包、立即数字节边界检查
- 中断处理函数经函数引用直接调用

</details>

<details>
<summary><b>运行时、GC 与分配器</b></summary>

- 线程本地分配缓冲从 per-CPU 改为 per-thread;分配计数器从全局原子量改为 per-CPU 字段
- 函数引用发布加屏障并同步;funcallable-instance 入口点同步
- 受限上下文中的分配统一到单个 `with-allocator-lock` 宏,覆盖全部七个加锁点,并带
  停世界检查
- 隔离 GC finalizer 错误;类哈希改用 weak-pointer-pair 并清理死键
- 空闲链 card table 更新线性化
- 被取代的实例布局原子发布

</details>

<details>
<summary><b>CLOS 与语言核心</b></summary>

- 修复 `restart-case` —— 此前它展开为字面 `NIL`
- `make-instance` 的 initarg 经协议校验;方法组合查找在标准泛函原型上派发
- 修正有效方法缓存路径、累积 `defgeneric` 声明、维护结构父类子类链、初始化结构布局
  类哈希
- `loop` 宏环境初始化、readtable 派发访问器加锁、显式声明 `format` 包遮蔽

</details>

<details>
<summary><b>Supervisor 与驱动</b></summary>

- virtio MMIO 设备经驱动注册表认领,取代内建派发表;GIC 中断按类型路由;带类型的
  IRQ FIFO
- AArch64 缓存与 DMA 维护范围对齐;按体系结构区分的 DMA flush
- USB/EHCI:qTD 出队与回收、周期表初始化、缓冲区分配、端口去抖,重写 HID 键鼠驱动
- 强制 pager 可写能力检查;拦截对未映射块的写
- 重启前同步磁盘与快照;加固 Intel GMA modeset 时序;限定 Intel HDA 复位轮询上界

</details>

<details>
<summary><b>测试</b></summary>

- 252 个宿主契约测试,无需构建映像即可运行
- 真实的 AArch64 `SCAVENGE-OBJECT` 代码生成回归
- 带注入故障的集成与压力矩阵,含 SMP / 单 CPU / 低内存变体,各自管理文件服务器
- 构建溯源清单:映像 SHA-256、版本、子树哈希、脏树标记、构建命令与工具版本

</details>

<details>
<summary><b>构建与项目结构</b></summary>

- 操作系统与构建系统共享同一条提交图,跨层改动与其测试一并评审发布
- `home/` 下的库直接纳入版本库而非子模块,上游变动无法改变本树的构建结果
  ([说明](docs/reference/vendored-libraries.md))
- AArch64 作为默认目标,提供图形化 QEMU 启动目标
- 472 份文档纳入自动校验

</details>

## 快速开始

### 环境要求

| | |
| --- | --- |
| SBCL | 64 位,带 Unicode(已验证 2.6.8) |
| QEMU | 含 `qemu-system-aarch64`(已验证 10.2.1) |
| Make | GNU Make |
| Quicklisp | 用于宿主侧构建库 |

```common-lisp
(ql:quickload '(alexandria iterate nibbles cl-fad cl-ppcre closer-mop trivial-gray-streams))
```

### 编译

```sh
git clone https://github.com/tiwe0/LBuild.git
cd LBuild
make asdf          # 用树内源码构建 ASDF
make cold-image    # 交叉编译出 lambda64.image
```

产物 `lambda64.image` 是一个声明 5 GiB 的稀疏文件,实际占盘约 590 MB。预编译映像
发布在 [Releases](https://github.com/tiwe0/LBuild/releases)。

### 启动

先在一个终端启动宿主文件服务器 —— Guest 要连它编译:

```sh
make run-file-server
```

再在另一个终端引导:

| 命令 | 加速方式 | 平台 |
| --- | --- | --- |
| `make hvf-arm64` | HVF | Apple Silicon |
| `make kvm-arm64` | KVM | Linux |
| `make qemu-arm64` | TCG | 任意平台 |

可用 `MEMORY`、`CPUS`、`RESOLUTION`、`FILE_SERVER_IP` 调整:

```sh
make hvf-arm64 MEMORY=8G CPUS=8 RESOLUTION=1920x1080
```

**首次引导约需二十分钟**,且在图形传输通道被认领之前屏幕一直是黑的。编译产生的
`.llf` 会写回 `home/`,因此后续引导几分钟即可到达桌面。

### 在线开发

系统走到 SWANK 后即可在转发端口上接受连接;此后发生的错误会挂起出错线程而不是
停机,可以就地检查:

```
M-x slime-connect RET 127.0.0.1 RET 4005
```

### 引导加载流程

```
SBCL(宿主)                      交叉编译 Lambda64 源码
    │
    ├─ 冷生成器 ───────────────▶ lambda64.image
    │
QEMU -kernel KBoot               从 virtio-blk 载入映像
    │
    ├─ supervisor bootstrap      分页、pager、GIC、定时器、调度器、SMP
    ├─ 冷启动                     运行时、包、CLOS
    ├─ 暖模块                     从映像载入预编译的 .llf
    ├─ 第四阶段                   其余系统经 TCP 2599 从宿主文件服务器取源码编译,
    │                            结果以 .llf 写回 home/
    ├─ IPL                       认领图形与输入、载入 GUI、启动合成器与桌面
    └─ 快照                       运行中的系统写回磁盘
```

第四阶段是首次引导慢、后续引导快的原因。末尾的快照则是系统能从停下的地方继续、
而不是每次冷启的原因。

### 已验证环境

| | |
| --- | --- |
| 宿主 | macOS 27.0,Apple Silicon |
| SBCL / QEMU | 2.6.8 / 10.2.1 |
| 加速 | HVF(`-machine virt -cpu host`);TCG 由测试套件覆盖 |
| Guest | 4 GB 内存、4 CPU、1280×800 |

`highmem` 必须保持开启,内存不低于 4 GB:第四阶段需要 4 GB 线以上的地址空间,
低于此 Guest 会报 `Addressing limited to 32 bits`。

Linux 上的 KVM 与继承自上游的 x86-64 目标不在本次验证范围内。

## 为什么选 Lisp

Lisp 系统天生自描述、自修改:编译器是运行映像的一部分,代码即数据,任何函数、类、
方法都能在系统运行时重新定义。在 Lambda64 中这一点贯穿到底层 —— 调度器和设备驱动
就是普通的 Lisp 对象,可以从连到活机器的 REPL 里重新编译。

这正是要点所在。一个能在运行时安全改写自身组件的操作系统,是**自我演进**系统的
天然基座:让模型进入回路,对一台从不需要停机的系统提出、编译并验证修改。在此之上
构建**AI 原生的操作系统**,是本项目的下一个目标。

需要说明的是:这部分工作尚未开始。上面列出的特性是当前已有的部分。

## 为什么选 ARM64

**指令集更简单。** AArch64 定长、规整,没有 x86 的变长编码、前缀堆叠和遗留模式。
对一个必须用 Lisp 编写、调试和推理的编译器后端来说,这直接减少了系统需要建模的
机器复杂度。

**硬件覆盖更广。** ARM64 横跨手机、平板、单板机、笔记本与服务器。优先面向它的
操作系统可以跟着硬件实际所在的地方走,而不被限制在桌面。

## 参与贡献

欢迎贡献。提交 PR 前请先跑:

```sh
make test-fast                 # 宿主契约测试 + 代码生成回归
python3 scripts/check-docs.py  # 文档校验
```

约定:

- **测语义,不测文本。** 本项目的契约测试断言的是语义,并经变异检验 —— 一个对着
  故意改坏的代码仍然通过的测试,本身就是缺陷。
- **遵守分配上下文约束。** 停世界期间、屏蔽中断期间、持有分配器锁期间的代码不得
  分配内存,详见[禁止分配的上下文](docs/development/allocation-forbidden-contexts.md)。
- **遵循代码风格。** 详见 [Common Lisp 风格](docs/development/common-lisp-style.md)。
- **在提交信息里写清为什么。** 改了什么 diff 里看得到,为什么改看不到。

较大的改动记录在[现代化路线图](docs/modernization/roadmap.md)与
[技术债登记](docs/modernization/debt-register.md)。工程文档从
[`docs/README.md`](docs/README.md) 开始。

## 致谢

Lambda64 的存在归功于两个项目:

- **[Mezzano](https://github.com/froggey/Mezzano)** —— 由 Henry Harrington 及
  众多贡献者开发,本项目在其之上继续。系统架构、编译器、对象模型与图形栈都出自
  他们之手。
- **[MBuild](https://github.com/froggey/MBuild)** —— 本仓库 fork 自该构建系统。

同样感谢 `home/` 下各 Common Lisp 库的维护者,来源清单见
[归档的第三方库](docs/reference/vendored-libraries.md)。

继承下来的包名与变量名中可能仍含 `mezzano` 字样,那些是兼容性标识。

## 许可证

MIT。完整文本与版权持有者列表见 [`Lambda64/COPYING`](Lambda64/COPYING)。
