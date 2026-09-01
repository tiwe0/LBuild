---
title: 子系统索引
status: active
owner: architecture
last-verified: 2026-08-31
verified-against: git:5422d69249c2104ff0ab1feff20806013cdba635
review-cycle: 90d
source-of-truth: code
---

# 子系统索引

- [编译器与镜像生成](compiler-and-image.md)
- [运行时与 Supervisor](runtime-and-supervisor.md)
- [驱动、存储与网络](drivers-storage-network.md)
- [GUI 与应用](gui-and-applications.md)

## 跨子系统变更护栏

| 组合 | 规则 |
| --- | --- |
| ARM64 寄存器分配/代码生成 + GC | 不在同一批次修改 |
| 加载顺序/ASDF 拆分 + warning 清理 | 不在同一批次修改 |
| 文件服务器协议安全 + Guest 网络栈 | 不在同一批次修改 |
| 构建配置注入 + LLF 缓存键 | 分开实施和验证 |
| legacy 名称迁移 + package/export/load graph | 分开实施 |
| 第三方 warning + 第一方 warning | 分账治理 |

跨边界工作应创建 [ADR](../../decisions/README.md) 或 [modernization initiative](../../modernization/initiatives/README.md)。
