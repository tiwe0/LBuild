---
title: 安全架构与门禁
status: active
owner: security
last-verified: 2026-08-31
verified-against: git:5422d69249c2104ff0ab1feff20806013cdba635
review-cycle: 30d
source-of-truth: code
---

# 安全架构与门禁

## 当前判定

现代化架构状态：**BLOCKED at Gate 0**。在宿主文件服务器完成安全收敛前，不应扩大远程访问范围、把它用于不可信网络或在其上增加更多操作能力。

## 关键边界

- [宿主文件服务器](host-file-server.md)：critical，涉及网络 reader、任意路径与写删操作。
- Guest Swank：Guest 内监听所有接口，无协议级认证。根 `Makefile` 的手工 QEMU 目标配置 loopback hostfwd，其他 runner 可能没有 4005 转发；物理/桥接网络仍可能直接暴露 Guest 服务。
- 构建脚本：可读写源码、配置、镜像和 submodule，应避免不可信输入进入 shell/Lisp reader。
- 第三方 submodule：应固定 revision、记录来源，并把第三方 warning/风险与第一方分账。

## Gate 0 退出条件

1. 文件服务器默认只绑定 loopback，远程监听必须显式开启。
2. 网络解析禁用 reader eval，拒绝非协议对象和资源耗尽输入。
3. 所有路径被规范化并约束在显式 source/home allowlist root 下；拒绝根外绝对路径、`..` 和 symlink 逃逸。现有协议兼容期可接收 allowlist 内的绝对路径，长期协议再迁移到 root-id + relative path。
4. 写入、删除和远程模式具有明确认证/授权策略，或默认完全禁用。
5. malicious `#.`、路径逃逸、未认证写删均有自动化负例。
6. 错误被结构化记录，清理后无残留监听器。
7. Swank 默认禁用或显式 opt-in；绑定、认证/隧道和物理/桥接部署边界有自动化或可复现验证。

关联计划：[M001 文件服务器加固](../modernization/initiatives/M001-host-file-server-hardening/README.md)、[M003 调试服务暴露边界](../modernization/initiatives/M003-debug-service-boundary/README.md)。
