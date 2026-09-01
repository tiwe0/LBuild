---
title: M001 宿主文件服务器加固
status: draft
owner: security
last-verified: 2026-08-31
verified-against: git:5422d69249c2104ff0ab1feff20806013cdba635
review-cycle: 30d
source-of-truth: code
initiative-status: proposed
---

# M001 宿主文件服务器加固

## 问题

宿主 TCP 文件服务器默认监听所有接口、缺少认证和 root confinement，并直接使用 Lisp reader 解析网络输入。它构成宿主代码执行与任意文件操作风险，阻断后续现代化阶段。

## 范围

- loopback 默认绑定与显式远程模式；
- 安全、有界协议解析；
- root confinement 与 symlink 逃逸防护；
- 默认只读、写删 capability/授权；
- 结构化错误、确定性资源清理和安全测试。

## 非范围

- Guest 网络栈重写；
- VirtIO-net 重构；
- 通用远程文件系统设计；
- Swank 协议替换。

## 实施顺序

1. 添加当前协议兼容测试和 malicious `#.` 回归，测试必须以“未执行副作用”为判定。
2. 增加路径规范化/逃逸单元测试。
3. 默认 loopback、禁用 reader eval、限制输入资源。
4. 分别声明 source root 与 home/fixture root。兼容现有 Guest 路径形式时，只接受 canonicalize 后落入这两个 allowlist root 的绝对路径；拒绝任何根外/未授权根路径。后续 root-id + relative path 协议另立 ADR/迁移计划。
5. 默认只读，将写删置于显式授权 capability 后；source/home 两根分别授权，不用一个模糊 root 隐藏双根语义。
6. 保留 `Lambda64/tests/guest/os-services.lisp` 的 `os.file-server-read-write`：测试环境对 fixture root 显式授予写删 capability；同一请求在默认无 capability 时必须拒绝，禁止删除、跳过或弱化原测试。
7. 集成测试验证 source/home 两根内的 Guest 正常读写、根外绝对路径/逃逸/symlink negative 场景拒绝、退出后端口清理。
8. 更新运维和协议文档；如改变线协议，创建 ADR。

## 验收矩阵

| 能力 | 正例 | 负例/安全 |
| --- | --- | --- |
| 监听 | loopback 可连接 | 非显式远程地址不可连接 |
| 解析 | 合法请求兼容 | `#.`、超长、深层、截断不执行且有界失败 |
| 路径 | source/home allowlist 内绝对路径工作 | 根外或未授权 root、`..`、symlink escape 拒绝 |
| 权限 | 原有 `os.file-server-read-write` 在显式 fixture capability 下通过 | 同请求在默认无 capability 时拒绝 |
| 生命周期 | 集成测试可完成 | 中断/超时后无 socket/临时文件泄漏 |

## 回滚

保留旧协议兼容仅限 loopback、受限 reader 和 root confinement 之后；不得以恢复公网监听或 reader eval 作为回滚方式。

## 关联

- [安全评估](../../../security/host-file-server.md)
- [测试缺口 T001](../../../testing/test-gap-register.md)
