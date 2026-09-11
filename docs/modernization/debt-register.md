---
title: 技术债登记
status: active
owner: architecture
last-verified: 2026-08-31
verified-against: git:5422d69249c2104ff0ab1feff20806013cdba635
review-cycle: 30d
source-of-truth: code
---

# 技术债登记

| ID | 区域 | 证据/问题 | 风险 | 下一步 | 归属 |
| --- | --- | --- | --- | --- | --- |
| D001 | Security | 文件服务器 `read-preserving-whitespace` + `0.0.0.0` + 任意路径写删 | critical | [M001](initiatives/M001-host-file-server-hardening/README.md) | security |
| D002 | Build | ASDF、cold-generator、IPL 多个加载图事实源 | high | 单一声明式加载清单 | build/compiler |
| D003 | Build | 临时配置覆盖/恢复不支持并发 | high | 显式配置输入与并发测试 | build |
| D004 | Compiler | 编译器/目标使用全局状态 | high | compiler/target context | compiler |
| D005 | LLF | 缓存主要只看源码 mtime。**本会话触发两次**：(1) 旧代码生成器产出的 `.llf` 使 guest 执行不存在的 `BRK #45`；(2) 改动 `Lambda64/supervisor/thread.lisp` 后，未重编的 `Lambda64/system/sync.lisp` 其 LLF 仍携带旧 `THREAD` 结构定义，暖加载时触发 sealed struct 重定义断言 | high | 内容寻址缓存键；至少要覆盖**被依赖的结构定义**，只看自身源文件 mtime 不够 | compiler/build |
| D006 | Reproducibility | 随机 image UUID、未排序 `maphash` | medium | 定义 reproducibility 模式 | image |
| D007 | Compiler | CAS fallback 自由变量 `place`。**已定位为根因并修复**：`Lambda64/compiler/package.lisp` 的 bootstrap 展开 `(progn (setf place new) old)` 漏进目标代码，使**每次 CAS 都报告成功**，互斥锁/伪原子门/唤醒竞态全线失效 | high | 已修；保留 guest 内三值自测与 `acquire-mutex` 不变量断言防回归 | compiler |
| D008 | Compiler/GC | ARM64 XOR swap 可能隐藏 live value；可达性/实际破坏尚待定向证明 | high | 独立正确性研究，勿与 GC 同批 | compiler/runtime |
| D009 | ARM64 | x13/x14 被 workaround 禁用；可疑 `:rax` metadata | high | ABI/codegen 测试 | compiler |
| D010 | Runtime | STW/pager/thread 缺少状态机测试 | high | Guest stress + fault injection | runtime |
| D011 | VirtIO | legacy v1、单队列、IRQ/flush TODO | high | 测试 seam 后分层演进 | io-platform |
| D012 | Network | ARP 过期禁用、配置/协议/驱动耦合 | medium | 网络契约测试 | networking |
| D013 | GUI | 无窗口/事件/damage/resize 自动化 | medium | host-pure + Guest 契约 | gui |
| D014 | GUI | 图标配置字符串读取/求值 | medium | 结构化 descriptor | gui |
| D015 | Errors | 多处 `ignore-errors` 丢失根因 | medium | 结构化 condition 与日志 | cross-cut |
| D016 | Warnings | 存量 warning 未分类、无新增门禁 | high | [M002](initiatives/M002-warning-baseline/README.md) | build/test |
| D017 | Image | cold-generator map/symbol table 参数疑似重复使用 `map-file` | medium | 定向生成器测试 | image |
| D018 | Security | Guest Swank 全接口监听、无协议认证；不同 QEMU/物理网络暴露边界不一致 | high | [M003](initiatives/M003-debug-service-boundary/README.md) | security/runtime |
| D019 | Branding | 品牌改名仅完成目录/镜像/引导菜单；包名 `mezzano.*`（27 个）、特性 `:mezzano`、kboot 二进制内 20 处 `mezzano:` 前缀仍为上游命名 | low | 仅做第一层（面向用户字符串）；第二/三层见下方分层与约束 | architecture |

规则：技术债表不是直接开工单。高风险或跨子系统条目先转为 initiative/ADR，明确非范围、冲突批次和验收矩阵。

## D019 改名分层与约束

改名代价高度不均，必须分层评估。以下数据实测于 `git:1f07257d782b742bac5c53a4bf1d90446f83c9aa`。

| 层 | 范围 | 规模 | 结论 |
| --- | --- | --- | --- |
| 一、面向用户字符串 | 引导菜单、横幅、文档、镜像名 | 菜单 8 项**已改**；kboot 二进制内 20 处**改不了** | 部分可做 |
| 二、包名 `mezzano.*` | 27 个包、约 7,286 处引用 | 机械替换 | 可做，但有代价 |
| 三、特性 `:mezzano` | 第一方 25 处；**第三方 `home/` 66 处、11 个库** | 不在本仓库 | **不建议改** |

### 第一层的实际边界

- `Lambda64/tools/kboot/kboot.cfg` 的 8 个菜单项**已经是 `Lambda64`**。
- 但每个菜单项体内的 `mezzano "hd0,2"` 是 **kboot 的 loader 命令名**，不是品牌串；
  它与 kboot 二进制绑定。
- `Lambda64/tools/kboot/` 下**只有预编译二进制，没有 C 源码**。二进制内 20 处
  `mezzano: ...` 前缀（如 `mezzano: Starting system.`）在拿到 kboot 源码并重建之前
  **无法修改**。
- Lisp 侧目前**没有**面向用户的 `"Mezzano"` 字面串，所以第一层在本仓库内实际已接近完成。

### 第三层为什么不建议改

`home/` 下 11 个第三方库含 66 处 `#+mezzano` / `#-mezzano`：
asdf、chipz、cl-fad、closer-mop、mcclim、nibbles、slime、static-vectors、
trivial-features、trivial-garbage、trivial-gray-streams。

这些是上游社区为 Mezzano 写的移植适配。改特性名意味着 fork 这 11 个库并永久承担上游同步成本。
若确需新身份，**同时 push 两个特性**（保留 `:mezzano` 兼容、另加新名）是唯一划算的方案。

### 次序建议

第二层的 7,286 处替换会让 `git blame` 与现代化批次（`f1a0dd50` 之后 320 个提交）的对照
显著变难。若计划复核那批提交，**应排在改名之前**，否则每次追溯都要跨一个全局重命名提交。

### 许可

改名做衍生品在上游宽松许可下通常可行，但须保留 attribution，具体以仓库 LICENSE 为准。
改名脚本不得连带替换版权声明。
