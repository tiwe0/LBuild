---
title: 历史文档映射
status: active
owner: maintainers
last-verified: 2026-08-31
verified-against: git:5422d69249c2104ff0ab1feff20806013cdba635
review-cycle: 90d
source-of-truth: documentation
---

# 历史文档映射

`Lambda64/doc/` 保留项目历史、内部实现笔记和设计背景，但其内容可能对应旧架构、旧名称或尚未实现的设计。不要删除，也不要默认当作当前契约。

| 历史文档 | 主题 | Authority | Verification | Replacement / 当前入口 |
| --- | --- | --- | --- | --- |
| `Lambda64/doc/Dualboot.md` | 双启动实验 | historical | 未逐项验证 | [运行与排障](../operations/README.md)；无当前双启动承诺 |
| `Lambda64/doc/atomic-extensions.md` | 原子操作扩展 | supporting | 待与 compiler/runtime 对照 | [编译器](../architecture/subsystems/compiler-and-image.md)、[运行时](../architecture/subsystems/runtime-and-supervisor.md) |
| `Lambda64/doc/defstruct-extensions.md` | `defstruct` 扩展 | supporting | 待与当前宏/运行时对照 | [编译器](../architecture/subsystems/compiler-and-image.md) |
| `Lambda64/doc/internals/abi.md` | ABI | supporting | ARM64/x86-64 需分别验证 | [编译器](../architecture/subsystems/compiler-and-image.md) |
| `Lambda64/doc/internals/compiler-frontend.md` | 编译器前端 | supporting | 已用于架构梳理，细节仍以代码为准 | [编译器](../architecture/subsystems/compiler-and-image.md) |
| `Lambda64/doc/internals/compiler-backend.md` | 编译器后端 | supporting | 已用于架构梳理，细节仍以代码为准 | [编译器](../architecture/subsystems/compiler-and-image.md) |
| `Lambda64/doc/internals/debugging-notes.md` | 调试方法 | historical | 命令/端口待逐项验证 | [运行与排障](../operations/README.md)、[M003](../modernization/initiatives/M003-debug-service-boundary/README.md) |
| `Lambda64/doc/internals/file-system.md` | 文件系统内部结构 | supporting | 待与当前 FS/mount 代码对照 | [驱动、存储与网络](../architecture/subsystems/drivers-storage-network.md) |
| `Lambda64/doc/internals/instances.md` | instance/object model | supporting | 已核对主要 header/area 概念 | [运行时与 Supervisor](../architecture/subsystems/runtime-and-supervisor.md) |
| `Lambda64/doc/internals/memory-layout.md` | 内存布局 | supporting | 待与 ARM64/current image 对照 | [运行时与 Supervisor](../architecture/subsystems/runtime-and-supervisor.md) |
| `Lambda64/doc/internals/supervisor-restrictions.md` | Supervisor 早期环境限制 | supporting | 已核对主要限制；以代码为准 | [运行时与 Supervisor](../architecture/subsystems/runtime-and-supervisor.md) |
| `Lambda64/doc/manual.md` | 用户手册/历史能力 | historical | 网络与硬件能力存在漂移 | [快速开始](../getting-started/README.md)、[系统上下文](../architecture/system-context.md) |
| `Lambda64/doc/quickstart.md` | 旧快速开始 | historical | 构建命令待更新 | [快速开始](../getting-started/README.md) |
| `Lambda64/gui/virgl/virgl-notes.md` | VirGL 实验笔记 | supporting | TODO/FIXME 未逐项验证 | [GUI 与应用](../architecture/subsystems/gui-and-applications.md) |
| `Lambda64/tests/README.md` | Guest 测试与运行说明 | current-supporting | 与根脚本共同验证 | [测试体系](../testing/README.md) |

## 迁移规则

1. 先验证历史结论在当前提交是否仍成立。
2. 将稳定、当前的机制写入 `docs/architecture/` 或 `docs/testing/`。
3. 将取舍写入 ADR，将未完成工作写入 initiative/技术债。
4. 映射表记录替代关系，不复制整篇旧文档。
