---
title: QEMU 运行模式
status: active
owner: build-and-test
last-verified: 2026-08-31
verified-against: git:5422d69249c2104ff0ab1feff20806013cdba635
review-cycle: 90d
source-of-truth: code
---

# QEMU 运行模式

| 入口 | 加速 | 用途 | 当前证据边界 |
| --- | --- | --- | --- |
| `make qemu-arm64` | TCG | 可移植手工图形启动 | 不自动执行 Guest 测试 |
| `make kvm-arm64` | KVM | Linux ARM64 加速 | 非当前确定性 CI 目标 |
| `make hvf-arm64` | HVF | Apple Silicon 加速 | 非当前确定性 CI 目标 |
| `make test-integration` | TCG | 自动化 Guest 矩阵 | 当前主要集成证明 |

公共参数由根 `Makefile` 的 `QEMU_COMMON_ARGS` 定义；本机覆盖使用 `local.mk`。不要从某个手工目标复制一份长期独立的 QEMU 命令，优先改公共参数或 runner 并同步测试。

## 网络差异

根手工目标包含 `127.0.0.1:4005 → Guest:4005` 的 loopback hostfwd；`Lambda64/tools/ci/run-arm64-smoke.sh` 的测试命令不应被假定具有同一转发。Guest 服务绑定和认证必须单独治理，详见 [M003](../modernization/initiatives/M003-debug-service-boundary/README.md)。

## 运行证据

自动化运行保存镜像/manifest、完整命令、serial log、timeout、退出码和 oracle。手工 GUI 启动不构成像素、输入或窗口生命周期的自动化证明。
