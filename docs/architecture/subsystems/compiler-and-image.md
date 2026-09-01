---
title: 编译器与镜像生成
status: active
owner: compiler
last-verified: 2026-08-31
verified-against: git:5422d69249c2104ff0ab1feff20806013cdba635
review-cycle: 90d
source-of-truth: code
---

# 编译器与镜像生成

## 职责

将 Common Lisp 源码在宿主环境中转换为目标架构机器码、对象与 GC 元数据，并将这些产物装载到可启动镜像。前端入口在 `Lambda64/compiler/compiler.lisp`，pass1 与 AST 在 `Lambda64/compiler/pass1.lisp`、`Lambda64/compiler/ast.lisp`；共享后端位于 `Lambda64/compiler/backend/`，ISA 后端位于 `Lambda64/compiler/backend/arm64/` 与 `Lambda64/compiler/backend/x86-64/`。

## 主流水线

1. 读取/转换源码并建立 AST。
2. 执行局部优化和控制流变换。
3. 转换为后端 IR、SSA/CFG，进行寄存器分配。
4. 进入 ARM64 或 x86-64 代码生成器。
5. `Lambda64/compiler/cross-file-compiler.lisp` 写出 LLF 命令/对象流。
6. `Lambda64/tools/cold-generator2/load.lisp` 校验目标头、装载机器码、GC 信息与 fixup。

关键实现：

- 前端：`Lambda64/compiler/compiler.lisp:70-212`
- AST：`Lambda64/compiler/ast.lisp:5-74,142-237`
- 后端 pass 顺序：`Lambda64/compiler/backend/backend.lisp:200-277`
- SSA/CFG：`Lambda64/compiler/backend/ssa.lisp`、`Lambda64/compiler/backend/cfg.lisp`
- 线性扫描寄存器分配：`Lambda64/compiler/backend/register-allocation.lisp`
- LLF：`Lambda64/compiler/cross-file-compiler.lisp:199-267`

## 当前约束

- `Lambda64/tools/cold-generator2/cold-generator.lisp` 和 cross compiler 使用全局目标/环境状态，限制可重入、多目标和并行构建。
- ARM64 可分配寄存器中禁用了 x13/x14，代码注释表明这是规避问题的 workaround（`Lambda64/compiler/backend/arm64/target.lisp`）。
- 类型检查默认关闭（`Lambda64/compiler/compiler.lisp`），应先建立兼容性基线再调整。
- LLF 缓存主要依赖源文件 mtime，不足以捕获编译器、宏和配置变化。
- ARM64 codegen 的 XOR swap 路径明确警告可能让 GC 暂时丢失 live value（`Lambda64/compiler/backend/arm64/codegen.lisp:504-521`）。

## 近期风险点

- `Lambda64/compiler/cross-compile.lisp` 的 CAS fallback 展开引用自由变量 `place`。
- `Lambda64/compiler/backend/arm64/codegen.lisp:925-926,1325,1342,1393` 多处 GC metadata 出现 `:rax`，`Lambda64/compiler/backend/arm64/object.lisp:251-276` 还包含 x86 IR/寄存器痕迹。必须先逐项确认可达性、死代码或共享代码误放，再按定向回归修复；不能只修单一出现点后结束。
- SSA 非局部退出、SIMD 寄存器对齐仍有显式 TODO。

## 现代化顺序

1. 固定 warning 与 codegen 回归基线。
2. 修复已确认的正确性问题，不同时改 GC。
3. 按[路线图 Phase 2 的 2A–2D](../../modernization/roadmap.md)执行：配置隔离 → LLF 缓存正确性 → 单一加载清单 → 显式 compiler/target context；每一小门独立提交、测试和回滚。
4. 只有 2A–2D 全部验收后，才考虑并行编译与多目标构建。

## 测试缺口

- 不同优化级别、类型检查开关、ARM64 ABI 边界的矩阵测试。
- SSA/CFG verifier 的负例测试。
- LLF 缓存失效与跨提交污染测试。
- ARM64/x86-64 同进程顺序构建的状态隔离测试。
