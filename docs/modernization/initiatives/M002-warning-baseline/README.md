---
title: M002 Warning 分类基线与新增门禁
status: draft
owner: build-and-test
last-verified: 2026-08-31
verified-against: git:5422d69249c2104ff0ab1feff20806013cdba635
review-cycle: 30d
source-of-truth: tests
initiative-status: proposed
---

# M002 Warning 分类基线与新增门禁

## 问题

镜像构建可完成，但产生大量 warning/style-warning；默认目标可能复用 LLF，当前又只依赖进程退出码，没有稳定的分类、数量基线或新增门禁。直接批量清理会把真实 bug、加载顺序、host/target 语义和第三方噪声混在一起。

## 范围

- 从完整冷构建日志提取结构化 warning inventory；
- 第一方/第三方分账；
- 稳定 fingerprint 与允许列表；
- CI 阻止新增第一方 warning；
- 分类别、小批次修复确定性问题。

## 分类

1. 确定性 bug/自由变量：如 `CROSS-SUPPORT::PLACE`。
2. 定义和加载顺序：如 `*IN-JUSTIFY*`、keymap/theme 全局变量。
3. host/target 语义泄漏：如 target-only `MAKE-ARRAY :AREA` 被宿主编译器处理。
4. implicit generic/package variance/redefinition。
5. 未使用变量/style warning。
6. 第三方 ASDF 命名与依赖 warning。

## 实施顺序

1. 以 `make clean && make test-integration`（或等价、已记录的 clean-build target）固定原始日志、工具链、manifest 和结果目录，禁止把默认增量集成运行当作 clean baseline。
2. 编写只读解析器，输出 category/source/symbol/fingerprint/count。
3. 人工审核分类，禁止只按文本全局忽略。
   第一方 implicit generic 默认归入 API declaration/load-order 缺陷；例外必须精确到 system、symbol、phase，并带 owner、原因、复审日期和双路径测试。
4. CI 对新增第一方 fingerprint 失败；存量按类别设下降预算。
5. 优先修复高置信 bug，再处理加载顺序和 style warning。
6. 第三方告警独立升级/补丁，不混入第一方提交。

## 验收

- 同一日志解析结果确定；路径/行号变化不会制造无意义 fingerprint。
- 新增第一方 warning 的 fixture 能让门禁失败。
- 允许列表条目带 owner、原因和到期/复审日期。
- 不使用全局 `muffle-warning` 或降低编译器告警级别。
- 每个修复批次通过定向测试、`make test-fast`，必要时通过完整集成。
