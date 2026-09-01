---
title: LBuild 工程文档中心
status: active
owner: maintainers
last-verified: 2026-08-31
verified-against: git:5422d69249c2104ff0ab1feff20806013cdba635
review-cycle: 90d
source-of-truth: documentation
---

# LBuild 工程文档中心

本目录是 LBuild/Lambda64 后续开发、维护与现代化工作的统一入口。文档按“理解系统 → 开发变更 → 验证交付 → 运营排障 → 演进决策”组织；历史材料继续保留在 `Lambda64/doc/`，但不默认视为当前事实。

## 导航

| 目录 | 用途 | 主要读者 |
| --- | --- | --- |
| [getting-started/](getting-started/README.md) | 环境、构建、首次运行 | 新贡献者 |
| [architecture/](architecture/README.md) | 系统上下文、构建启动链、子系统边界 | 开发者、架构维护者 |
| [development/](development/README.md) | 源码布局、变更约束、调试方法 | 日常开发者 |
| [testing/](testing/README.md) | 测试分层、Guest 协议、覆盖缺口 | 开发者、CI 维护者 |
| [operations/](operations/README.md) | QEMU、宿主服务、证据与故障排查 | 集成与运行维护者 |
| [security/](security/README.md) | 信任边界与安全阻断项 | 所有维护者 |
| [modernization/](modernization/README.md) | 路线图、技术债、改造计划 | 项目负责人、实现者 |
| [decisions/](decisions/README.md) | 架构决策记录（ADR） | 决策参与者 |
| [reference/](reference/README.md) | 术语、命令、历史文档映射 | 所有人 |
| [meta/](meta/README.md) | 文档治理、模板与生命周期 | 文档维护者 |

## 当前工程结论

1. **快速层可作为当前开发基线；完整集成必须按结果目录判定。** `make test-fast` 已在本提交的本轮验证中通过。`make test-integration` 的通过结论只来自相应 `test-results/<run-id>/summary.tsv`、serial oracle 和 manifest，不能由镜像生成或 QEMU 启动推断。该目标可能复用已有 LLF；真正 clean 的验证需先执行 `make clean`。
2. **当前不是“先大改再补测试”的阶段。** 编译器、GC、调度器、分页器、VirtIO、文件系统和 GUI 都存在强耦合或全局状态，必须先建立契约测试与可复现基线。
3. **安全 Gate 0 阻断后续网络扩展。** 宿主文件服务器当前默认监听所有接口，并使用 Common Lisp reader 直接解析未认证网络输入；详见 [security/host-file-server.md](security/host-file-server.md)。
4. **现代化以小批次、可回滚、可验证为原则。** 具体阶段见 [modernization/roadmap.md](modernization/roadmap.md)。

## 阅读路径

- 第一次接触：本页 → [快速开始](getting-started/README.md) → [系统上下文](architecture/system-context.md) → [测试体系](testing/README.md)。
- 修改编译器/运行时：先读对应[子系统文档](architecture/subsystems/README.md)，再读[变更护栏](development/README.md)。
- 处理现代化任务：从[路线图](modernization/roadmap.md)进入对应 initiative，不直接从技术债表开工。
- 遇到旧说明冲突：查询[历史文档映射](reference/legacy-doc-map.md)，以代码、测试和已接受 ADR 为准。

## 文档约束

- 每篇非索引文档应包含状态、负责人、验证提交和复审周期。
- “已完成”必须同时具备实现、测试、验证证据和文档更新。
- 代码路径应精确到文件，关键结论尽量精确到行区间。
- 快照事实不得写成永久事实；更新规则见 [文档治理策略](meta/documentation-policy.md)。

主题事实源：测试命令与能力以 [testing/README.md](testing/README.md) 为准；文件服务器安全以 [security/host-file-server.md](security/host-file-server.md) 为准；其他页面只保留摘要与链接。
