---
title: 宿主文件服务器生命周期
status: active
owner: build-and-test
last-verified: 2026-08-31
verified-against: git:5422d69249c2104ff0ab1feff20806013cdba635
review-cycle: 30d
source-of-truth: code
---

# 宿主文件服务器生命周期

安全事实与修复要求的唯一事实源是[宿主文件服务器安全评估](../security/host-file-server.md)。本页只描述现有运行生命周期。

## 手工模式

```sh
make run-file-server
```

根 `run-file-server.lisp` 装载 `Lambda64/file-server/` 的 ASDF 系统并启动 TCP 2599。当前实现默认监听所有接口，只能在可信隔离环境使用。

## 自动测试模式

`scripts/run-local-test-matrix.sh`：

1. 拒绝接管已存在的 TCP 2599 listener；
2. 后台启动 `make run-file-server` 并保存日志；
3. 等待端口就绪后启动 QEMU 场景；
4. 结束、失败或中断时清理服务；
5. 将文件服务器日志与场景证据放入同一结果目录。

测试完成后必须确认无 `qemu-system-aarch64`、文件服务器 SBCL 和 TCP 2599 listener 残留。M001 完成前，不在不可信网络上运行 exploit fixture；安全负例使用 loopback、临时端口和无害 sentinel，并保证清理。
