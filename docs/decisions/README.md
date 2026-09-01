---
title: 架构决策记录
status: active
owner: architecture
last-verified: 2026-08-31
verified-against: git:5422d69249c2104ff0ab1feff20806013cdba635
review-cycle: 180d
source-of-truth: documentation
---

# 架构决策记录（ADR）

ADR 用于记录影响多个版本或子系统的不可显然取舍。文件名为 `NNNN-short-title.md`，从 [0000 模板](0000-template.md) 创建。

状态：`proposed → accepted → superseded/deprecated`，也可为 `rejected`。已接受 ADR 不原地改写历史结论；新决策通过 `superseded-by` 指向替代 ADR。

需要 ADR 的典型情况：线协议变化、镜像/LLF 格式、目标 ABI、核心生命周期、兼容性承诺、依赖引入、多个加载图合并方案。
