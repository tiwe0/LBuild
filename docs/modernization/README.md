---
title: 现代化总览
status: active
owner: architecture
last-verified: 2026-08-31
verified-against: git:5422d69249c2104ff0ab1feff20806013cdba635
review-cycle: 30d
source-of-truth: documentation
---

# 现代化总览

目标不是一次性重写 Lambda64，而是在维持“可构建、可启动、可回滚”的前提下，逐步把隐式契约转换为测试、显式接口和可维护文档。

- [路线图](roadmap.md)：阶段、入口和退出条件。
- [技术债登记](debt-register.md)：问题、证据、风险和归属。
- [TODO/FIXME 完成台账](todo-fixme/README.md)：全量遗留项、规格、证据与完成状态。
- [Initiatives](initiatives/README.md)：可执行、可验收的工作包。

## 原则

1. 安全和正确性优先于结构美化。
2. 每个 initiative 只跨越必要边界，保留明确非范围。
3. 先测试后重构；覆盖不足时先锁定现状。
4. 优先删除重复事实源和复用现有能力，不先增加框架/依赖。
5. “完成”以验收矩阵和实际证据为准，不以代码合入为准。

## 当前状态

- 快速测试基线可用。
- 完整集成测试可运行但耗时长，warning 数量较大。
- Gate 0 因宿主文件服务器安全边界阻断。
- Gate 1 需要 warning 分类、第一方/第三方分账和新增告警门禁。
