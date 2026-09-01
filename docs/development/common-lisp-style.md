---
title: 第一方 Common Lisp 编码规范
status: active
owner: maintainers
last-verified: 2026-08-31
verified-against: git:5422d69249c2104ff0ab1feff20806013cdba635
review-cycle: 90d
source-of-truth: code
---

# 第一方 Common Lisp 编码规范

## 适用范围

本规范只适用于 `Lambda64/`、`build-cold-image.lisp` 和 `run-file-server.lisp` 中的第一方源码。`home/` 是外部依赖边界，不应因统一格式或 warning 清理而被全仓重写；生成的 `.llf` 也不应手工编辑。

`.editorconfig` 规定第一方源码使用 UTF-8、LF 和末尾换行。历史文件中的制表符和局部缩进差异不构成一次性重排任务：只在实质性修改的行遵循本规范，并保持无关行稳定。

## 代码约定

- Lisp 新增或修改的表单使用空格缩进；延续相邻稳定代码的布局，不进行无关格式化。
- 跨包 API 通过 package export、import 或 local nickname 表达；不要以新增 `::` 绕过边界。
- 可扩展操作在第一个 `defmethod` 前显式声明 `defgeneric`；setter 以独立的 `(defgeneric (setf ...))` 表达。
- generic 的 lambda list 是协议的一部分。新增 method 前先复核调用者、现有 method 和 cold-image 加载顺序。
- 确定未使用的形参使用 `declare (ignore ...)` 或 `_` 风格的局部命名；不要用全局 warning 静默替代修复。
- 新增注释说明行为、边界或原因，而非逐字复述代码。

## 自动门禁与变更流程

```sh
make lisp-style-check
make test-fast
make docs-check
git diff --check
```

`make lisp-style-check` 验证第一方源码的 UTF-8/LF/末尾换行、lowercase kebab-case 文件名，并锁定当前已修复的 generic 声明与 cold-image 加载顺序。它不声称覆盖所有历史 warning；warning 分类、允许例外和后续批次以 [M002](../modernization/initiatives/M002-warning-baseline/README.md) 为准。`make style-check` 是兼容别名。

涉及 Guest 启动或 cold-image 的改动，完成快速检查后还必须运行 `make test-integration`。风格统一应当随着行为修复逐批推进，而不是以全仓自动格式化制造不可审阅的大型 diff。
