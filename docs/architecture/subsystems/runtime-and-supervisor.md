---
title: 运行时与 Supervisor
status: active
owner: runtime
last-verified: 2026-08-31
verified-against: git:5422d69249c2104ff0ab1feff20806013cdba635
review-cycle: 90d
source-of-truth: code
---

# 运行时与 Supervisor

## 职责

Supervisor 提供早期启动、异常/中断、线程与调度、页表/分页、设备初始化等系统核心能力；运行时实现对象分配、对象模型和垃圾回收。它们通过对象布局、保存状态、寄存器约定和内存 area 紧密耦合。

## 关键入口

- 启动：`Lambda64/supervisor/entry.lisp:136-193`
- ARM64 平台：`Lambda64/supervisor/arm64/platform.lisp:23-119`
- 中断：`Lambda64/supervisor/arm64/interrupts.lisp:3-120`
- 调度/STW：`Lambda64/supervisor/thread.lisp:350-414,723-751,986-1046`
- 分页：`Lambda64/supervisor/pager.lisp:1106-1275`
- 分配：`Lambda64/runtime/allocate.lisp`
- GC：`Lambda64/system/gc.lisp:96-174,1848-2008,2149-2175`

## 核心契约

1. 编译器生成的栈图、寄存器 live 信息与 GC 扫描必须一致。
2. 分配器的对象布局、tag、header 和 area 语义必须与 GC、序列化/镜像生成一致。
3. stop-the-world 必须覆盖所有可运行线程，并与分页器、锁和中断状态正确交互。
4. 早期启动阶段不能依赖尚未可用的普通运行时服务；历史限制说明见 `Lambda64/doc/internals/supervisor-restrictions.md`。

## 风险

- 并发、GC、分页和异常路径缺少细粒度可重复测试。
- 部分 wired function 分配路径仍有 TODO。
- 调度器与 STW 状态机主要靠集成启动验证，失败时定位成本高。
- 编译器 codegen/寄存器约定变化可能造成延迟出现的 GC 损坏。

## 变更护栏

- 修改 GC 前必须有对象布局、根扫描和 STW 契约测试。
- 不与 ARM64 寄存器分配/codegen 同批修改。
- 调度、锁、分页分别小批次演进；每批保留 Guest stress 测试和超时诊断。
- 早期启动错误必须保留原始 condition/backtrace，避免新增静默 `ignore-errors`。

## 测试缺口

- 启动阶段顺序和失败注入。
- 多核调度、线程退出、STW 与锁竞争。
- pager fault、回收、writeback 和低内存路径。
- 各 area 的分配边界、GC 后存活性与对象搬迁。
