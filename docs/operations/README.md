---
title: 运行与排障
status: active
owner: build-and-test
last-verified: 2026-08-31
verified-against: git:5422d69249c2104ff0ab1feff20806013cdba635
review-cycle: 90d
source-of-truth: tests
---

# 运行与排障

- [QEMU 运行模式](qemu.md)
- [宿主文件服务器生命周期](file-server.md)
- [来源证明与可复现性](reproducible-builds.md)

测试命令和通过条件的唯一事实源是[测试体系](../testing/README.md)；本目录只描述运行、证据收集和故障处置。

## QEMU 集成运行

推荐通过 `make test-integration` 或 `Lambda64/tools/ci/run-arm64-smoke.sh` 间接启动，避免手工命令与 CI 漂移。保存以下证据：完整 QEMU 命令、镜像 SHA、manifest、serial log、timeout、退出码和 oracle 判定。

## 故障定位顺序

1. **构建未完成**：查宿主 SBCL 首个 error/condition，不要只看尾部 warning。
2. **镜像被拒绝**：核对 manifest 格式、repository SHA、dirty 状态、Lambda64 tree 和 image SHA。
3. **QEMU 未启动**：检查二进制、架构、镜像路径、端口占用和磁盘空间。
4. **Guest 启动超时**：按 supervisor entry → pager/thread → device → IPL 的最后串口阶段定位。
5. **Guest 测试失败**：按 test id 和 condition 查 runner 原始输出，再查看 oracle 是否正确分类。
6. **测试退出后**：确认 QEMU、宿主 SBCL 文件服务器和 TCP 2599 均已清理。

## 安全提示

当前宿主文件服务器不适合暴露在不可信网络。运行完整集成测试前阅读 [安全说明](../security/host-file-server.md)。在 Gate 0 修复前，应通过宿主防火墙/隔离网络减少暴露，但这不是代码层修复。

## 结果目录

`scripts/run-local-test-matrix.sh` 将每次运行写入独立的 `test-results/<timestamp>-<kind>-<pid>/`。诊断时以该目录内证据为单位，不混用不同运行的 serial log 或 manifest。

## CI 与发布边界

`.github/workflows/ci.yml` 复用本地 manifest、QEMU runner 和 serial oracle。当前文档只证明 CI 与本地测试共用关键工具，不宣称镜像按位可复现或具备正式发布流水线；来源证明边界见[可复现性说明](reproducible-builds.md)。
