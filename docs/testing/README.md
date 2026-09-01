---
title: 测试体系
status: active
owner: build-and-test
last-verified: 2026-08-31
verified-against: git:5422d69249c2104ff0ab1feff20806013cdba635
review-cycle: 60d
source-of-truth: tests
---

# 测试体系

## 入口

```sh
make test-fast         # 宿主侧快速契约，不启动完整 Guest
make test-integration  # 镜像构建（可复用 LLF）+ 文件服务器 + QEMU ARM64 + Guest + serial oracle
```

当前 HEAD 上 `make test-fast` 已通过。完整集成测试耗时长，且默认不清理已有 LLF；建立 clean baseline 时使用 `make clean && make test-integration`。结果应以 `test-results/<run-id>/` 下的 `summary.tsv`、报告、串口日志和 manifest 为准，而不是以“QEMU 能启动”代替通过。

## 文档

- [测试金字塔与门禁](test-pyramid.md)
- [Guest 测试协议](guest-test-protocol.md)
- [覆盖缺口登记](test-gap-register.md)

## 主要实现

- 根测试目标：`Makefile`
- 场景编排：`scripts/run-local-test-matrix.sh`
- manifest：`scripts/write-test-manifest.sh`
- QEMU runner：`Lambda64/tools/ci/run-arm64-smoke.sh`
- 串口判定：`Lambda64/tools/ci/assert-serial-log.sh`
- Guest 目录：`Lambda64/tests/guest/runner.lisp`
- CI：`.github/workflows/ci.yml` 与 stress workflow

## 证据规则

每个测试结论至少记录：提交 SHA、dirty 状态、镜像摘要、目标架构、QEMU 场景、开始/结束时间、退出码、超时和 serial oracle 结果。manifest v2 已覆盖其中一部分，后续应统一由一个解析器消费。
