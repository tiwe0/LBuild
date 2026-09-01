---
title: 文档 Owner 注册表
status: active
owner: maintainers
last-verified: 2026-08-31
verified-against: git:5422d69249c2104ff0ab1feff20806013cdba635
review-cycle: 180d
source-of-truth: documentation
---

# 文档 Owner 注册表

Owner 是稳定责任域，不是个人。新增值前先更新本表。

| Owner | 责任边界 |
| --- | --- |
| `maintainers` | 顶层入口、跨域维护规则与最终归属协调 |
| `architecture` | 系统边界、ADR、路线图与技术债 |
| `build-and-test` | Make/scripts、manifest、runner、CI 与测试协议 |
| `compiler` | 前端、后端、目标 ABI、LLF 与 cold generator |
| `runtime` | 对象模型、分配、GC、Supervisor、线程与分页 |
| `io-platform` | 总线、设备、DMA/IRQ、block 与文件系统边界 |
| `networking` | NIC 以上网络协议与配置 |
| `gui` | surface、compositor、桌面和应用生命周期 |
| `security` | 信任边界、威胁、加固门禁与安全测试 |
| `cross-cut` | 无单一组件归属的可观察性、错误和兼容性债务 |

Owner 负责安排复审并确保结论有当前证据；它不表示该域只有一个实现者。
