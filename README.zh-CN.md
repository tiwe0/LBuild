<div align="center">

# Lambda64

**一个完全以 Common Lisp 实现的操作系统:内核、驱动、编译器、图形环境。**

[![CI](https://github.com/tiwe0/LBuild/actions/workflows/ci.yml/badge.svg)](https://github.com/tiwe0/LBuild/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](#许可证)
[![Language: Common Lisp](https://img.shields.io/badge/language-Common%20Lisp-lightgrey.svg)](https://common-lisp.net/)
[![Target: AArch64](https://img.shields.io/badge/target-AArch64-success.svg)](#为什么选-arm64)

[English](README.md) · **简体中文**

</div>

---

Lambda64 是一个完全以 Common Lisp 实现的操作系统。supervisor、设备驱动、内存管理、
编译器与窗口系统均以该语言编写。源码树包含 334 个 Lisp 文件,不含任何 C 代码;
唯一的非 Lisp 组件是负责将控制权移交给映像的 KBoot 引导垫片。

本项目在 [Mezzano](https://github.com/froggey/Mezzano) 基础上继续开发,确立 AArch64
为主要目标平台,并在该架构上实现了完整可用的图形桌面。

编译器是运行映像的组成部分,因此任何组件都可以在系统不重启的前提下重新定义、重新
编译并重新载入。这构成了本项目既定方向的技术基础,详见
[为什么选 Lisp](#为什么选-lisp)。

## 系统特性

| | |
| --- | --- |
| **内核** | 纯 Common Lisp supervisor:分页、调度、SMP、中断 |
| **内存** | 分代复制式 GC,新生代/老年代各自半空间 |
| **编译器** | 自举、基于 SSA,具备 AArch64 与 x86-64 后端 |
| **语言** | 完整 Common Lisp:CLOS 与 MOP、条件与重启、宏、reader、`format` |
| **持久化** | 映像快照:完整的运行中系统写入磁盘,并可自该状态恢复 |
| **图形** | 合成器、窗口管理、字体渲染、AArch64 SIMD 位块传输 |
| **网络** | Ethernet、ARP、IP、TCP、UDP、DHCP、DNS、HTTP |
| **文件系统** | ext4、FAT32、本地、远程、HTTP |
| **驱动** | virtio 块/网络/GPU/输入,USB EHCI 与 HID 键鼠,RTL8168 网卡,Intel GMA 显示,Intel HDA 音频 |
| **在线开发** | SWANK,允许 SLIME 连接并修改运行中的系统 |

### 应用

发行版包含两个 REPL、`med` 编辑器、文件管理器、图片查看器、IRC 客户端、telnet
客户端、Mandelbrot 浏览器、内存监视器、系统检视器(`peek`)、事件追踪器与设置面板,
均由合成器承载。仓库另附 [McCLIM](https://github.com/froggey/McCLIM),可用于开发
其他应用。

## 相对 Mezzano 的改进

最主要的成果是 AArch64 从无法引导的状态达到了可用的桌面环境。全部改动归为以下
八个方面。

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

## 安装与使用

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

构建产物为 `lambda64.image`,是一个标称容量 5 GiB 的稀疏文件,实际占用磁盘约
590 MB。

### 启动

Guest 需连接宿主文件服务器编译其余系统,故须在启动 Guest 之前先运行该服务:

```sh
make run-file-server
```

随后以下列目标之一引导系统:

| 命令 | 加速方式 | 平台 |
| --- | --- | --- |
| `make hvf-arm64` | HVF | Apple Silicon |
| `make kvm-arm64` | KVM | Linux |
| `make qemu-arm64` | TCG | 任意平台 |

可用 `MEMORY`、`CPUS`、`RESOLUTION`、`FILE_SERVER_IP` 调整:

```sh
make hvf-arm64 MEMORY=8G CPUS=8 RESOLUTION=1920x1080
```

首次引导约需二十分钟,在初始化后期认领图形传输通道之前显示保持无输出状态。编译
产生的 `.llf` 文件写回 `home/`,后续引导复用这些文件,可在数分钟内到达桌面。

### 在线开发

初始化到达 SWANK 后,系统即在转发端口上接受连接。此后产生的错误将挂起出错线程而
非停机,故障因此可就地检查:

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

第四阶段决定了首次引导的耗时与后续引导的快速。末尾的快照使系统得以从既有状态恢复,
而非每次从冷态初始化。

### 已验证环境

| | |
| --- | --- |
| 宿主 | macOS 27.0,Apple Silicon |
| SBCL / QEMU | 2.6.8 / 10.2.1 |
| 加速 | HVF(`-machine virt -cpu host`);TCG 由测试套件覆盖 |
| Guest | 4 GB 内存、4 CPU、1280×800 |

`highmem` 必须保持开启,Guest 内存不得低于 4 GB。第四阶段需要 4 GB 边界以上的地址
空间,低于此值时 Guest 报告 `Addressing limited to 32 bits`。

Linux 上的 KVM 与继承自上游的 x86-64 目标不在本次验证范围之内。

## 为什么选 Lisp

Lisp 系统在构造上即具备自描述与自修改能力:编译器是运行映像的组成部分,程序文本
即数据,函数、类与方法均可在系统运行期间重新定义。在 Lambda64 中该性质贯通至最底层
——调度器与设备驱动本身即普通 Lisp 对象,可从连接至运行实例的 REPL 重新编译。

这是本项目的主要立论依据。一个能够在运行时安全改写自身组件的操作系统,适合作为
自我演进系统的基座:模型参与提出、编译并验证修改,而目标实例无须停机。在此基础上
构建 AI 原生的操作系统,是本项目的下一个目标。

该项工作尚未启动。上文所述能力均为当前已实现的部分。

## 为什么选 ARM64

AArch64 采用定长、规整的编码,不存在 x86 的变长指令形式、前缀序列与遗留运行模式。
对于必须以 Lisp 实现、调试并推理的编译器后端而言,这直接降低了系统需要建模的机器
复杂度。

AArch64 覆盖的硬件范围亦更广,自移动设备与单板计算机至笔记本与服务器。优先面向该
架构,可使系统跟随硬件的实际部署状况,而不局限于桌面平台。

## 参与贡献

提交 Pull Request 前须通过以下检查:

```sh
make test-fast                 # 宿主契约测试 + 代码生成回归
python3 scripts/check-docs.py  # 文档校验
```

对贡献代码的要求:

- **契约测试须断言语义而非源码文本。** 本仓库的测试经变异检验:对故意改错的代码
  仍然通过的测试,其本身即为缺陷。
- **须遵守分配上下文约束。** 在停世界期间、中断屏蔽期间或持有分配器锁期间执行的
  代码不得分配内存,详见
  [禁止分配的上下文](docs/development/allocation-forbidden-contexts.md)。
- **源码须符合项目风格约定。** 详见
  [Common Lisp 风格](docs/development/common-lisp-style.md)。
- **提交信息须说明改动理由。** 改动内容可从 diff 得知,改动理由不能。

较大规模的改动记录于[现代化路线图](docs/modernization/roadmap.md)与
[技术债登记](docs/modernization/debt-register.md)。工程文档自
[`docs/README.md`](docs/README.md) 起。

## 致谢

本项目源自以下两个项目:

- **[Mezzano](https://github.com/froggey/Mezzano)**,由 Sylvia Harrington 及众多
  贡献者开发,是本项目所继续的操作系统。其系统架构、编译器、对象模型与图形栈构成
  了 Lambda64 的基础。
- **[MBuild](https://github.com/froggey/MBuild)**,本仓库自该构建系统 fork。

同时向 `home/` 下所收录各 Common Lisp 库的维护者致谢,来源清单见
[归档的第三方库](docs/reference/vendored-libraries.md)。

继承的包名与变量名中可能仍含 `mezzano` 字样。此类标识仅用于兼容,不代表当前命名。

## 许可证

MIT。完整文本与版权持有者列表见 [`Lambda64/COPYING`](Lambda64/COPYING)。
