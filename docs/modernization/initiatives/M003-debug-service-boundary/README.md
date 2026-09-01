---
title: M003 调试服务暴露边界
status: draft
owner: security
last-verified: 2026-08-31
verified-against: git:5422d69249c2104ff0ab1feff20806013cdba635
review-cycle: 30d
source-of-truth: code
initiative-status: proposed
---

# M003 调试服务暴露边界

## 问题

`Lambda64/ipl.lisp:158-161` 启动的 Guest Swank 监听 Guest 全接口，未见协议级认证。根 `Makefile` 的手工 QEMU 目标将宿主 4005 转发限制在 loopback，但 `Lambda64/tools/run-qemu-arm64` 等路径可能没有该 hostfwd；物理或桥接网络也不经过宿主 loopback 限制。

## 范围

- 默认开关和显式 opt-in；
- Guest 绑定地址与可达性；
- hostfwd、无转发、桥接/物理三类部署模式；
- 认证或仅经受控隧道访问的边界；
- 启停、失败和日志契约。

## 非范围

- 重写 Swank 协议或调试器；
- Guest 网络栈重构；
- 与 M001 文件服务器协议合并实施。

## 验收

| 场景 | 预期 |
| --- | --- |
| 默认生产/普通启动 | Swank 必须禁用；不得以 loopback 绑定替代显式 opt-in |
| 显式开发 opt-in | 启动并记录绑定、端口和保护方式；受限绑定、认证或受控隧道为 opt-in 后的附加条件 |
| 根 Makefile hostfwd | 宿主只在 loopback 可达 |
| 无 hostfwd runner | 宿主不产生 4005 监听 |
| 桥接/物理网络 | 无认证服务不可全网可达；策略有验证记录 |
| 退出/失败 | listener 清理，日志保留原因 |

如果选择保留全接口监听，必须由已接受 ADR 说明为何认证/隧道边界足够，以及如何在所有启动路径上强制执行。
