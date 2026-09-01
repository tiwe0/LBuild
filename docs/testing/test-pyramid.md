---
title: 测试金字塔与门禁
status: active
owner: build-and-test
last-verified: 2026-08-31
verified-against: git:5422d69249c2104ff0ab1feff20806013cdba635
review-cycle: 60d
source-of-truth: tests
---

# 测试金字塔与门禁

| 层级 | 目标 | 当前入口 | 主要缺口 |
| --- | --- | --- | --- |
| L0 静态契约 | shell、目录、符号、格式 | `make test-fast` 子脚本 | Lisp lint、路径/链接统一校验 |
| L1 宿主单元/属性测试 | 编译器 IR、blit、解析、缓存键 | 少量脚本/回归 | 覆盖很少，定位主要靠集成 |
| L2 代码生成/镜像契约 | ABI、GC metadata、LLF、manifest | ARM64 回归与冷构建 | 多优化级别、缓存失效、双目标隔离 |
| L3 Guest 子系统测试 | 线程、GC、文件、网络、GUI | Guest runner 目录 | 并发/错误注入/GUI 生命周期不足 |
| L4 QEMU 集成 | 启动到 Guest 完整协议 | `make test-integration` | 主要是 VirtIO + TCG |
| L5 平台/长期压力 | 多核、长时间、故障恢复 | CI stress 部分覆盖 | 物理 ARM64、KVM/HVF、设备矩阵 |

## 门禁建议

- **Gate 0 安全**：宿主文件服务器不再默认暴露远程代码/文件能力。
- **Gate 1 基线**：warning 分类和新增 warning 门禁；`test-fast` 稳定。
- **Gate 2 正确性**：编译器/运行时关键 bug 有定向回归。
- **Gate 3 架构演进**：显式 context、加载清单和设备 API 可分批迁移。

## 测试顺序

运行依赖必须串行验证：L0/L1 → 构建/manifest → QEMU/Guest → serial oracle。失败后优先读取本层原始证据，不应继续下游并用后续超时覆盖根因。

## 反模式

- 只判断进程退出码而不解析 Guest 协议。
- 只保留最后一段日志。
- 用旧镜像测试新源码但未验证 manifest。
- 将 TCG 通过扩展为所有硬件支持声明。
- 在没有 baseline 的情况下把 warning 全局静默。
