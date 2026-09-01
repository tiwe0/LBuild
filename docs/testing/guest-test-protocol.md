---
title: Guest 测试协议
status: active
owner: build-and-test
last-verified: 2026-08-31
verified-against: git:5422d69249c2104ff0ab1feff20806013cdba635
review-cycle: 60d
source-of-truth: tests
---

# Guest 测试协议

Guest 测试目录由 `Lambda64/tests/guest/runner.lisp` 定义，当前包含 26 个测试。Guest 通过串口输出阶段和用例标记，宿主 `assert-serial-log.sh` 判断完成、失败、fatal marker 与超时。

## 协议职责

- Guest runner：稳定的 test id、开始/结束/失败标记、最终汇总。
- QEMU runner：进程生命周期、timeout、串口捕获和退出状态。
- serial oracle：只基于已定义协议与 fatal marker 判定，不推测未输出状态。
- matrix runner：将不同场景的命令、manifest、日志、状态统一保存。

## 当前限制

协议以文本 grep 为主，扩展字段和失败上下文容易产生兼容性问题。现代化时应引入版本化的单行结构化记录（例如 JSON Lines 或严格 key-value），同时在迁移期保持旧 marker。

建议最小字段：`protocol_version`、`run_id`、`test_id`、`phase`、`status`、`duration_ms`、`condition_type`、`message`。宿主只接受已知协议版本，未知字段可忽略，未知必需版本必须失败。

## 变更规则

1. 先为 oracle 添加正例、负例、截断、重复和乱序日志测试。
2. Guest 与宿主协议变化必须同批提交。
3. 新协议稳定前保留文本原始日志，结构化摘要不能成为唯一证据。
