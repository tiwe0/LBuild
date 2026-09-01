---
title: 来源证明与可复现性
status: active
owner: build-and-test
last-verified: 2026-08-31
verified-against: git:5422d69249c2104ff0ab1feff20806013cdba635
review-cycle: 60d
source-of-truth: code
---

# 来源证明与可复现性

## 当前能证明的内容

`scripts/write-test-manifest.sh` 记录镜像 SHA-256、仓库 revision、dirty 状态、Lambda64 tree、构建命令与工具版本。它支持来源追踪和旧镜像拒绝，但不等价于按位可复现。

## 当前不能证明的内容

- `make test-integration` 默认不清理 LLF；
- LLF 缓存键主要基于 header 与 source mtime；
- image UUID 包含随机值；
- 部分哈希表通过未排序 `maphash` 序列化；
- Git revision 获取存在静默失败路径。

因此不得仅凭两次普通构建“成功”宣称可复现。

## 基线流程

```sh
make clean
make test-integration
```

重复 clean build 时分别保存 manifest、工具版本、LLF/镜像摘要和结构化差异。Phase 2 的目标是提供 deterministic mode 与允许差异清单；Phase 5 才决定是否以及在哪些平台承诺 bit-identical。

发布门禁中若 revision 获取失败，应显式标记 `unknown`、保留 condition，并失败退出；不得把缺失 provenance 当作可忽略信息。
