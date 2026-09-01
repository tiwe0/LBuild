---
title: 快速开始
status: active
owner: build-and-test
last-verified: 2026-08-31
verified-against: git:5422d69249c2104ff0ab1feff20806013cdba635
review-cycle: 90d
source-of-truth: tests
---

# 快速开始

本页只提供入口，测试契约以 [测试体系](../testing/README.md) 为准，安全结论以 [宿主文件服务器安全评估](../security/host-file-server.md) 为准。

## 先决条件

- 64-bit、支持 Unicode 的近期 SBCL；
- Quicklisp；
- GNU Make 与 Git；
- `qemu-system-aarch64`；
- 足够的磁盘空间保存约 5 GiB 镜像和测试结果。

机器专用的 QEMU、网络或工具链覆盖写在未跟踪的 `local.mk`，不要提交个人路径。

## 仓库边界

- 根目录负责宿主构建、镜像管理、QEMU 启动和测试编排。
- `Lambda64/` 是主要第一方系统源码。
- `home/` 包含大量 Git submodule，构建前必须保证递归初始化完整。
- `lambda64.image` 是约 5 GiB 的生成镜像，不应把它当作普通源码文件处理。

## 最小验证

```sh
git submodule update --init --recursive
make test-fast
```

`test-fast` 当前覆盖脚本契约、ARM64 smoke runner、value-register、Guest 测试目录、串口 oracle、shell 语法与 SCAVENGE-OBJECT codegen 回归，不启动完整 Guest。

## 构建镜像

```sh
make deps       # 初始化 home/ 下递归 submodules
make asdf       # 构建仓库使用的 ASDF
make cold-image # 生成 lambda64.image，可能复用有效 LLF
```

需要排除现有 LLF/镜像影响时使用：

```sh
make clean
make cold-image
```

## 完整集成验证

```sh
make test-integration
```

该命令会构建测试镜像（可能复用已有 LLF），并在 QEMU `virt` + TCG 中启动 ARM64 Guest。它可能耗时较长，并会临时启动宿主文件服务器。需要真正 clean 的 warning/可复现性基线时，先执行 `make clean`。执行前应阅读：

- [构建与启动生命周期](../architecture/build-and-boot-lifecycle.md)
- [测试体系](../testing/README.md)
- [宿主文件服务器风险](../security/host-file-server.md)

## 支持边界

当前自动化证据主要覆盖 QEMU TCG，不等价于物理 ARM64、KVM/HVF、所有设备组合或像素级 GUI 正确性。新增兼容性声明必须绑定明确的平台矩阵和测试证据。

## 手工启动

在一个终端启动宿主文件服务器，另一个终端启动 Guest：

```sh
make run-file-server
make qemu-arm64  # portable TCG
# make kvm-arm64 # Linux/KVM
# make hvf-arm64 # Apple Silicon/HVF
```

文件服务器当前只适合可信隔离环境，具体风险与生命周期要求见[安全评估](../security/host-file-server.md)和[运维说明](../operations/file-server.md)。

## 下一步

- 理解系统：[系统上下文](../architecture/system-context.md)
- 开始修改：[开发指南](../development/README.md)
- 排查失败：[运行与排障](../operations/README.md)
