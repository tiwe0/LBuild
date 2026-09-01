---
title: 现代化路线图
status: active
owner: architecture
last-verified: 2026-08-31
verified-against: git:5422d69249c2104ff0ab1feff20806013cdba635
review-cycle: 30d
source-of-truth: documentation
---

# 现代化路线图

路线图只定义阶段与门禁；具体设计和验收放在 initiative/ADR 中。

## Phase 0：安全与证据基线

**入口**：项目能在当前工具链构建并运行快速测试。
**工作**：[M001 宿主文件服务器加固](initiatives/M001-host-file-server-hardening/README.md)、[M002 warning 基线](initiatives/M002-warning-baseline/README.md)、[M003 调试服务暴露边界](initiatives/M003-debug-service-boundary/README.md)、统一测试证据字段。
**退出**：安全 Gate 0 全部满足；Swank 默认禁用或显式 opt-in 且部署边界有测试；新增第一方 warning 能被阻止；快速/集成测试证据可追踪。

## Phase 1：确定性正确性修复

**入口**：Phase 0 完成。
**工作**：CAS fallback 自由变量、`*in-justify*` 定义顺序、host/target `MAKE-ARRAY :AREA` 泄漏、ARM64 codegen/metadata 可疑点；每项独立回归。
**退出**：高置信第一方 bug 清零；ARM64 文件中的 x86 register/IR 引用逐项有可达性结论和回归；warning 基线下降且集成测试不回退。

## Phase 2：构建与编译环境显式化

**入口**：关键 codegen/GC 契约稳定。各小门独立提交、测试和回滚，不把配置注入、缓存键、加载图或 warning 清理混在同一批次。

- **2A 配置隔离**：替换 tracked 配置覆盖/恢复，证明并发构建互不污染。
- **2B 缓存正确性**：定义包含编译器、宏环境、目标和 features 的 LLF 键，覆盖 stale/wrong-arch/truncated 负例。
- **2C 加载清单**：从单一声明式清单生成 ASDF/cold/warm/IPL 顺序；不与 warning 清理同批。
- **2D 显式 context**：逐步引入 compiler/target context，验证同进程多目标和重复构建状态隔离。
- **贯穿证据**：统一 manifest parser；Git revision 获取失败必须显式记录 `unknown` 与 condition，并使发布门禁失败。

**退出**：2A–2D 各自验收；加载顺序只有一个事实源；提供 deterministic build mode、两次真正 clean build 的结构化差异报告和允许差异清单，但此阶段不承诺按位相同。

## Phase 3：运行时与 I/O 边界

**入口**：构建可重复且关键运行时测试完善。
**工作**：线程/STW/pager 契约、device/bus/resource、DMA/IRQ、异步 block I/O、网络/挂载生命周期。
**退出**：核心状态机可独立验证，QEMU 故障注入覆盖关键错误路径。

## Phase 4：GUI 与应用平台

**入口**：运行时和 I/O 边界稳定。
**工作**：surface/blit 纯测试、结构化 app descriptor、app/window session、稳定 compositor API、第三方扩展点。
**退出**：窗口/输入/damage/resize 生命周期自动化，应用资源释放有统一契约。

## Phase 5：性能、平台与发布

**入口**：功能边界和测试矩阵稳定。
**工作**：并行构建、镜像增量/内容寻址、物理 ARM64/KVM/HVF 矩阵、在 Phase 2 deterministic mode 上评估并收敛按位可复现、发布 provenance。
**退出**：性能指标有基线，兼容性声明与目标矩阵一致，发布流程可审计。
