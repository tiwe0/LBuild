---
title: 开发与变更指南
status: active
owner: maintainers
last-verified: 2026-08-31
verified-against: git:5422d69249c2104ff0ab1feff20806013cdba635
review-cycle: 90d
source-of-truth: code
---

# 开发与变更指南

## 源码布局

| 路径 | 职责 |
| --- | --- |
| `Makefile`, `scripts/` | 宿主构建、测试、manifest 与结果编排 |
| `Lambda64/compiler/` | 前端、IR、后端、目标代码生成与交叉编译 |
| `Lambda64/tools/cold-generator2/` | LLF 装载与目标镜像生成 |
| `Lambda64/runtime/`, `Lambda64/system/` | 对象、分配、GC、加载器及 Lisp 运行时 |
| `Lambda64/supervisor/` | 启动、线程、分页、异常、平台与低层设备 |
| `Lambda64/drivers/`, `disk/`, `file/`, `net/` | I/O、块设备、文件系统与网络 |
| `Lambda64/gui/` | 图形基础、合成器、桌面与应用 |
| `Lambda64/tests/` | Guest 测试、runner 与测试说明 |
| `home/` | 外部/用户态 submodules，不默认视为第一方可随意重写代码 |

## 标准变更循环

1. 明确行为、平台范围、成功条件和不修改范围。
2. 找到实际加载图和调用链，不只依据文件名或历史文档。
3. 若覆盖不足，先增加能锁定旧行为的回归/契约测试。
4. 每次只处理一种风险：正确性、安全、warning、结构或性能。
5. 先运行最小定向测试，再运行 `make test-fast`；涉及镜像/Guest 的改动再运行 `make test-integration`。
6. 更新相应子系统文档、技术债或 initiative，并记录验证提交/结果目录。

## 必须拆批的变更

参见[子系统跨域护栏](../architecture/subsystems/README.md)。尤其禁止在同一批次同时修改 ARM64 寄存器分配/codegen 与 GC，也不要把加载图重构混入 warning 清理。

## Warning 治理

不允许以全局静默、降低编译器告警级别或批量 `muffle-warning` 代替修复。先建立机器可读的分类基线：

- 第一方确定性 bug/自由变量；
- 定义/加载顺序；
- 宿主与目标语义泄漏；
- 隐式 generic/API 声明或加载顺序；第一方默认视为待修缺陷，只有精确到 system、symbol、phase 且带 owner/复审日期的已验证边界才能例外；
- 第三方 ASDF/包命名；
- 未使用变量与 style warning。

第一方和第三方分别记账，新增 warning 失败、存量 warning 按 initiative 逐类下降。详见 [M002](../modernization/initiatives/M002-warning-baseline/README.md)。

第一方源码的编码范围、generic 声明规则和可执行门禁见 [Common Lisp 编码规范](common-lisp-style.md)。

## 调试证据

- 保存完整宿主构建日志，不只截取最后一行。
- Guest 失败保存 QEMU 命令、serial log、scenario、timeout 和 manifest。
- 不新增吞掉根因的 `ignore-errors`；预期失败应保留 condition 类型和上下文。
- 结论要区分静态代码证据、测试证明和推断。

## 提交前检查

```sh
make test-fast
make docs-check
git diff --check
git status --short
```

涉及 Guest、启动、编译器、GC、驱动或镜像格式时，补充 `make test-integration` 或明确说明未运行原因。
