<div align="center">

# LBuild

**一个能在 ARM64 上冷启动进入图形桌面的 Lisp 操作系统。**

[![CI](https://github.com/tiwe0/LBuild/actions/workflows/ci.yml/badge.svg)](https://github.com/tiwe0/LBuild/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](Lambda64/COPYING)
[![Language: Common Lisp](https://img.shields.io/badge/language-Common%20Lisp-lightgrey.svg)](https://common-lisp.net/)
[![Target: AArch64](https://img.shields.io/badge/target-AArch64-success.svg)](docs/architecture/arm64-boot-bring-up.md)

[English](README.md) · **简体中文**

</div>

---

LBuild 构建 **Lambda64** —— 一个完全用 Common Lisp 写成的操作系统:内核、驱动、
编译器、图形界面都在内。宿主工具链用 SBCL 交叉编译出冷镜像,Guest 随后自己把
剩下的部分从源码编译完,最终进入图形桌面。

操作系统源码位于 `Lambda64/`,是一个普通的一方目录而非子模块,其原始 Git 历史
未经压缩直接合入。LBuild fork 自
[froggey/MBuild](https://github.com/froggey/MBuild),后者仍是上游构建系统项目。

## 概览

| | |
| --- | --- |
| **目标平台** | ARM64 / AArch64,运行于 QEMU `virt` |
| **宿主工具链** | 带 Unicode 的 SBCL + Quicklisp |
| **产物** | `lambda64.image` —— 声明 5 GiB 的稀疏文件,实际占盘约 590 MiB |
| **引导链路** | 冷加载 → 暖模块 → 经 TCP 2599 的第四阶段编译 → 桌面 |
| **可用设备** | virtio GPU 帧缓冲(1280×800)、键盘、鼠标 |

## 当前状态

**ARM64 已完整引导。** 冷加载、暖模块、经宿主文件服务器的第四阶段依赖编译、
GUI、桌面,以及收尾快照全部走完。帧缓冲、键盘、鼠标均可用。

走到这一步定位并修复了 **21 个根因**,横跨冷生成器、编译器、运行时与 GC、
supervisor 与驱动、网络与文件系统各层。每一条都按**症状 / 根因 / 为何难找**
记录在
**[`docs/architecture/arm64-boot-bring-up.md`](docs/architecture/arm64-boot-bring-up.md)**。
该文末节归纳的三个反复出现的模式,是改动本树前最值得先读的部分 —— 多数缺陷都出自
这三个模式。

已知限制记录在[技术债登记](docs/modernization/debt-register.md)。目前肉眼可见的
是 **D024**:virtio-gpu 每帧同步传输并刷新整个裁剪区,因此 1280×800 下窗口出现时
是可见的逐步重绘,而不是瞬间呈现。

## 快速开始

```sh
git clone --recurse-submodules https://github.com/tiwe0/LBuild.git
cd LBuild
```

安装构建所需的 Common Lisp 系统:

```common-lisp
(ql:quickload '(alexandria iterate nibbles cl-fad cl-ppcre closer-mop trivial-gray-streams))
```

然后构建并启动:

```sh
make deps asdf      # 子模块 + ASDF
make cold-image     # 交叉编译出 lambda64.image
make run-file-server   # 另开一个终端 —— Guest 要连它取源码编译
make hvf-arm64      # Apple Silicon(通用 TCG 用 qemu-arm64,Linux 用 kvm-arm64)
```

> [!IMPORTANT]
> **首次引导很慢,而且大部分时间是黑屏。** Guest 要经文件服务器把 GUI 和各库从
> 源码编译一遍,光 `ext4.lisp` 就约二十分钟(见 D021);画面要等到 IPL 后期认领
> GPU 传输通道之后才会亮起来。生成的 `.llf` 会写回 `home/`,所以后续引导会复用
> 它们,几分钟就能到桌面。
>
> 看进度要跟串口日志,不要盯着窗口。**看起来卡住的引导通常并没有卡** —— 先确认
> QEMU 仍在吃 CPU、日志仍在增长,再下结论。这两个信号,以及真的停住时该怎么读
> Guest panic,都写在
> [reading-arm64-panics.md](docs/development/reading-arm64-panics.md)。

> [!WARNING]
> **安全提示。** 遗留的宿主文件服务器监听所有网络接口,并且用 Common Lisp reader
> 解析未经认证的输入。在文档所述的 Gate 0 加固完成之前,只能在可信的隔离主机上
> 运行它。参见
> [`docs/security/host-file-server.md`](docs/security/host-file-server.md)。

## 运行

| 目标 | 加速方式 | 适用于 |
| --- | --- | --- |
| `make qemu-arm64` | TCG | 任意平台(慢) |
| `make kvm-arm64` | KVM | Linux |
| `make hvf-arm64` | HVF | Apple Silicon |

三者都会挂上 virtio GPU、键盘和鼠标。当用户态网络的 `10.0.2.2` 不适用时,可覆盖
Guest 看到的文件服务器地址:

```sh
make FILE_SERVER_IP=192.168.1.10 cold-image
```

### 在线调试

IPL 走到 SWANK 之后,Guest 会在转发端口上接受连接;并且此后发生的错误会
**把出错线程挂起,而不是停机** —— 故障可以就地检查,不必重现:

```
M-x slime-connect RET 127.0.0.1 RET 4005
```

## 已验证的配置

以下全部是在**同一台机器**上开发并验证的。其他加速方式只是「按理可行」,不是「已
验证」—— 依赖它们之前请先知道这一点。

| | 已验证的取值 |
| --- | --- |
| 宿主系统 | macOS 27.0 (Darwin),Apple Silicon |
| SBCL | 2.6.8 |
| QEMU | 10.2.1 |
| 加速方式 | `hvf` —— `-machine virt -accel hvf -cpu host` |
| 内存 | `MEMORY=4G` |
| CPU 数 | `CPUS=4` |
| 分辨率 | `RESOLUTION=1280x800` |

验证通过的引导所用的完整设备参数:

```text
-machine virt -accel hvf -cpu host
-m 4G -smp 4 -kernel Lambda64/tools/kboot/kboot-generic-arm64.bin
-serial stdio -monitor none -no-reboot
-device virtio-gpu-device,xres=1280,yres=800
-device virtio-keyboard-device
-device virtio-mouse-device
-drive if=none,file=lambda64.image,id=blk,format=raw
-device virtio-blk-device,drive=blk
-netdev user,id=vmnic,hostname=lambda64,hostfwd=tcp:127.0.0.1:4005-:4005
-device virtio-net-device,netdev=vmnic
-semihosting-config enable=on,target=native
```

其中两项是承重的,而且很容易被「顺手优化」成引导失败:

- **`highmem` 必须保持开启。** `highmem=off` 会把 Guest 内存压到 4 GB 线以下
  (`Addressing limited to 32 bits`)。第四阶段依赖加载需要超过这个量,否则函数页
  会被换出 —— 而处于禁中断区间的代码一旦碰到被换出的页,就直接死在
  `page-fault-no-irqs`。
- **`MEMORY=4G` 是下限,不是偏好。** 把它从旧默认值提上来的,正是同一个第四阶段
  加载过程。

同一台机器上还跑过 **TCG** 路径:每次 `test-integration` 和 `test-stress` 都用
`-snapshot` 以 TCG 引导。

**完全没有验证过的:** `make kvm-arm64`(需要 Linux 宿主),以及从上游继承下来的
x86-64 源码 —— 本树并不构建它。

## 测试

测试体系以本地为主,GitHub Actions 复用同一套镜像清单、Guest 协议、冒烟运行器和
串口判定器。

| 目标 | 覆盖内容 |
| --- | --- |
| `make test-unit` | 构建脚本与宿主契约测试 |
| `make test-codegen` | 真实的 ARM64 `SCAVENGE-OBJECT` 编译器回归 |
| `make test-fast` | 以上两层快速测试 |
| `make test-integration` | 构建测试镜像,再跑正向引导与注入故障引导 |
| `make test-stress` | 重复的 SMP、单 CPU、低内存、注入故障 |
| `make test-all` | 完整本地测试套件 |

集成与压力测试目标会自行启停文件服务器,始终以 QEMU TCG + `-snapshot` 引导,并把
报告存到 `test-results/`。它们**不会**去接管已存在的 TCP 2599 监听。耗时参数可以
显式覆盖:

```sh
make test-stress STRESS_REPETITIONS=5 LOCAL_TEST_TIMEOUT_SECONDS=6000
make test-all TEST_RESULTS_ROOT=/path/to/test-results
```

<details>
<summary><b>构建溯源与测试镜像</b></summary>

```sh
make test-image     # CI 配置 + 溯源清单
make test-scripts   # 只跑构建脚本回归,不构建镜像
```

`test-image` 会强制 `CI=true`,要求镜像、map 和符号表都存在且非空,并写出
`lambda64.test-manifest`。清单记录镜像的 SHA-256、精确仓库版本、Lambda64 子树
哈希、工作区是否脏、构建命令,以及 SBCL/QEMU 版本。消费方必须拒绝格式错误的
清单,正式 CI 必须拒绝脏树。

开发期间清单会如实记录「脏的单体仓库」。本地矩阵显式选择接受这类镜像进行测试,
并把该决定记入证据;干净的自动化流程不会启用这个选项。

</details>

## 相对最初版本的改进

自 fork 以来 502 个提交。这里列的是**相对最初版本的全部增量**,因此既包含 LBuild
自己的工作,也包含期间合并进来的上游工作 —— 其中最大的一项是
**ARM64 从「引导不起来」变成「能进入可用的桌面」**。

<details open>
<summary><b>引导与 bring-up(ARM64)</b></summary>

- 修复 21 个根因,从冷生成器一直到驱动层;每条的症状、根因与为何难找都记在
  [引导修复记录](docs/architecture/arm64-boot-bring-up.md)
- 冷分页 bootstrap 加固:等待队列在开中断前初始化、分页建立**期间**就服务 pager、
  分页发现前先启用调度、存储空闲链 bootstrap 与 pager 之间定序
- 正确的 EL1h 异常返回;线程保持在 `SP_EL0` / EL1t 栈模式
- ARM64 通用定时器推迟到时间子系统初始化后再开,改用直接写寄存器,并对早期定时器
  中断加保护
- 开中断的时机挪到调度器就绪之后
- 主线程栈提升到 16 MB,并对已发布的函数预先触页

</details>

<details>
<summary><b>编译器与后端</b></summary>

- **SSA 正确性:** 恢复 NLX contour 的 CFG 建模、强制在进入 SSA 前完成关键边拆分、
  统一支配块编号
- ARM64 与 x86 两侧都把 NLX 跳转表作为 trailer 发射
- **ARM64:** 128 位 memref DCAS 下降、指针 CAS、字面量池载入宽度解码、可编码的
  立即数偏移、可回绕的逻辑掩码、大参数个数检查、GC 安全的寄存器交换、保留 GC
  scratch 寄存器、SIMD 溢出对齐、`tbz`/`tbnz` 反汇编
- **x86:** 紧凑化栈布局、`push imm8` 短形式、反向标量 SSE 移动、字节谓词临时量、
  浮点相等
- **表示分析:** 修正过度激进的 `ub64` 提升、保留不相交整数类型的交集、精确标量
  复短浮点提升、装箱单精度浮点直接在目标位置构造
- 调用规范化过程中保留 debug value;已证明不可达的调用直接终止而非发射

</details>

<details>
<summary><b>冷生成器与镜像序列化</b></summary>

- 修复**每一个** `(SETF ...)` 定义都被丢弃的问题 —— 函数名表用了弱键,而
  `(SETF foo)` 这种名字是每次调用现场新 cons 出来的列表,于是立刻被回收
- 确定性的根遍历顺序;对象初始化改走工作队列
- 保留结构槽的 initfunction、类元数据与源码位置
- 冷字符串支持宽字符、数组秩校验、未装箱槽位打包、立即数字节边界检查
- 中断处理函数经 FREF 直接调用

</details>

<details>
<summary><b>运行时、GC 与分配器</b></summary>

- TLAB 从 per-CPU 改为 per-thread;分配计数器从全局原子量改为 per-CPU 字段
- 函数引用的发布加内存屏障并同步;funcallable-instance 入口点同步
- 受限上下文中的分配收敛为**单个** `with-allocator-lock` 宏,覆盖全部七个加锁点,
  并带停世界检查 —— 此前这条规则只在其中一处被正确写出
- 隔离 GC finalizer 的错误;类哈希快表改用 weak-pointer-pair 并清理死键
- 空闲链 card table 更新线性化
- 被取代的实例布局原子发布

</details>

<details>
<summary><b>CLOS 与语言核心</b></summary>

- 修复 `restart-case` 展开 —— 此前它对**所有**用法都展开成字面的 `NIL`
- `make-instance` 的 initarg 经协议校验;方法组合的查找改在标准泛函原型上派发
- 修正 EMF 缓存路径、累积 `DEFGENERIC` 声明、维护结构父类的子类链、初始化结构
  布局的类哈希
- `loop` 宏环境初始化、readtable 派发访问器加锁、显式声明 `format` 的包遮蔽

</details>

<details>
<summary><b>Supervisor 与驱动</b></summary>

- virtio MMIO 设备改由注册表交给各自驱动认领,而非内建 `case`;GIC 中断按类型
  路由;带类型的 IRQ FIFO
- ARM64 缓存与 DMA 维护范围对齐;按体系结构区分的 DMA flush
- USB/EHCI:qTD 出队与回收、周期表初始化、缓冲区分配、端口去抖,以及重写的 HID
  键盘与鼠标驱动
- 强制检查 pager 的可写能力;拦截对未映射块的写
- 重启前同步磁盘与快照;加固 Intel GMA 的 modeset 时序;限定 Intel HDA 控制器
  复位轮询的上界

</details>

<details>
<summary><b>测试</b></summary>

- **252 个宿主契约测试**,不需要构建镜像即可运行
- 真实的 ARM64 `SCAVENGE-OBJECT` 代码生成回归
- 带注入故障的集成与压力矩阵,含 SMP / 单 CPU / 低内存变体,各自管理自己的文件
  服务器,并以 TCG + `-snapshot` 引导
- 构建溯源清单,记录镜像 SHA-256、精确版本、Lambda64 子树哈希、脏树标记、构建
  命令与工具版本

</details>

<details>
<summary><b>构建系统与文档</b></summary>

- Lambda64 以一方目录形式、保留完整历史合入,跨层改动与其测试共享同一条提交图
- ARM64 作为默认目标、图形化的 QEMU 启动目标、`local.mk` 覆盖机制,不再需要第二份
  checkout
- **471 份文档**纳入校验器(`scripts/check-docs.py`),包括引导修复记录、panic
  阅读指南、禁止分配上下文规则、技术债登记与现代化路线图

</details>

## 仓库结构

```text
LBuild/
├── Lambda64/    操作系统本体 —— supervisor、运行时、编译器、GUI
├── docs/        持续维护的工程文档
├── home/        Guest 可见的源码;编译出的 .llf 也回写到这里
├── scripts/     构建与测试工具
└── Makefile
```

`local.mk` 可用于机器相关的 QEMU、网络或工具链覆盖,但日常开发不需要第二份
checkout。

## 文档

从 **[`docs/README.md`](docs/README.md)** 开始 —— 架构、子系统边界、测试、运维、
安全,以及分阶段的现代化路线图。

| 该读哪篇 | 什么时候读 |
| --- | --- |
| [ARM64 引导修复记录](docs/architecture/arm64-boot-bring-up.md) | 动引导、分配或代码生成之前 |
| [读懂 ARM64 panic](docs/development/reading-arm64-panics.md) | Guest panic 了,或者引导停住了 |
| [禁止分配的上下文](docs/development/allocation-forbidden-contexts.md) | 改 supervisor 或分配器时 |
| [技术债登记](docs/modernization/debt-register.md) | 接手已知的待办工作 |

`Lambda64/doc/` 下的历史笔记仍是有用的背景资料,但不是当前的契约。

## 可复现构建

仓库自带构建所需的全部一方源码,只有第三方库是子模块。Lambda64 与构建系统共享同
一条提交图,因此跨层改动及其测试可以原子地评审和发布。

## 与上游的关系

LBuild 是 Lambda64 的构建工具。MBuild 是其上游,引用它是为了历史与署名,而不是
作为面向本项目的构建命令。

继承下来的 Common Lisp 包名和配置变量中可能仍含 `mezzano` 字样。那些是兼容性标识,
不代表当前的项目命名。

## 许可证

MIT。完整文本与版权持有者列表见 [`Lambda64/COPYING`](Lambda64/COPYING)。
