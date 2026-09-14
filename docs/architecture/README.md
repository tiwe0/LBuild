---
title: 架构总览
status: active
owner: architecture
last-verified: 2026-08-31
verified-against: git:5422d69249c2104ff0ab1feff20806013cdba635
review-cycle: 90d
source-of-truth: code
---

# 架构总览

LBuild 是构建与验证入口，Lambda64 是以 Common Lisp 实现的系统主体。系统包含宿主交叉编译器、镜像生成器、ARM64 运行时/内核、驱动与文件系统、网络栈、GUI 和 Guest 应用。

## 核心文档

- [系统上下文](system-context.md)：宿主、镜像、Guest 与外部依赖的边界。
- [构建与启动生命周期](build-and-boot-lifecycle.md)：从 SBCL 到 QEMU Guest 的执行链。
- [四阶段构建与依赖加载](four-stage-build-and-dependencies.md)：冷/暖切分，以及第四阶段经 TCP 2599 从 `home/` 加载依赖的机制与标准化注意事项。
- [ARM64 引导修复记录](arm64-boot-bring-up.md)：把 ARM64 从「启动即死」修到完整进入桌面所定位的 21 个根因，按层次给出症状、根因与为何难找；末节归纳的三个反复出现的模式，改动本树前值得先读。
- [子系统索引](subsystems/README.md)：编译器、运行时、I/O、GUI 的职责与风险。

## 当前架构特征

- 构建时依赖宿主 SBCL，通过交叉编译和 LLF 产物生成目标镜像。
- 编译器前端、共享后端和 ISA 后端按文件层次区分，但目标/编译环境仍大量依赖全局动态状态。
- Supervisor 负责启动、线程、调度、分页、异常和硬件抽象；GC 与分配器直接依赖对象布局和保存状态契约。
- PCI/VirtIO/磁盘/网络以 CLOS generic 和直接寄存器/DMA 操作为主，尚未形成统一的设备资源生命周期框架。
- GUI 由 surface/blit、compositor、窗口事件与应用层组成，Guest 端可运行，但自动化行为测试很少。

## 变更原则

1. 先用契约测试固定行为，再拆分全局状态和隐式加载顺序。
2. 编译器寄存器分配/代码生成与 GC 不在同一批次修改。
3. ASDF/加载图重构与 warning 清理不在同一批次修改。
4. 宿主文件服务器安全修复与 Guest 网络栈重构不在同一批次修改。
5. 每个跨子系统变更必须有 ADR 或 modernization initiative。
