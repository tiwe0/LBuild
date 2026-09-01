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
| D005 | LLF | 缓存主要只看源码 mtime | high | 内容寻址缓存键 | compiler/build |
| D006 | Reproducibility | 随机 image UUID、未排序 `maphash` | medium | 定义 reproducibility 模式 | image |
| D007 | Compiler | CAS fallback 自由变量 `place` | high | 独立回归与修复 | compiler |
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

规则：技术债表不是直接开工单。高风险或跨子系统条目先转为 initiative/ADR，明确非范围、冲突批次和验收矩阵。
