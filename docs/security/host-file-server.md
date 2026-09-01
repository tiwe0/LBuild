---
title: 宿主文件服务器安全评估
status: active
owner: security
last-verified: 2026-08-31
verified-against: git:5422d69249c2104ff0ab1feff20806013cdba635
review-cycle: 30d
source-of-truth: code
---

# 宿主文件服务器安全评估

## 结论

**严重级别：Critical。** 当前实现不应监听不可信网络。风险来自三个条件组合：默认绑定所有接口、无认证的文件操作、直接使用 Common Lisp reader 读取网络输入且未关闭 reader eval。

## 代码证据

- `Lambda64/file-server/server.lisp:166-172`：对 socket 输入调用 `read-preserving-whitespace`，未绑定 `*read-eval*` 为 `nil`。Common Lisp `#.` reader macro 可在读取阶段执行宿主代码。
- `Lambda64/file-server/server.lisp:198-205,226-234`：包括 SBCL 路径在内，监听地址为 `0.0.0.0`。
- `Lambda64/file-server/server.lisp:50-68,95-103,159-164`：协议包含打开、写入和删除文件操作。
- 根 `run-file-server.lisp` 与 `Makefile`：测试流程会以默认配置启动服务。
- 服务缺少认证、授权和 root confinement，错误处理包含 `ignore-errors`，会降低审计能力。

## 影响

在攻击者可连接 TCP 2599 的条件下，风险不仅是读取测试文件，还可能包括宿主 Lisp reader 代码执行，以及以构建用户权限进行任意路径文件读写/删除。是否能被利用取决于网络可达性和宿主权限，但代码边界本身不安全。

## 修复边界

本项只处理宿主文件服务器，不同时重写 Guest 网络栈。

1. 默认绑定 `127.0.0.1`/`::1`；远程模式使用显式参数。
2. 协议解析至少在 `(*read-eval* nil)` 与受限 package/readtable 下执行，并限制对象深度/长度；更稳妥的长期方案是替换为非 Lisp-reader 的长度前缀结构化协议。
3. 规范化并验证路径：当前兼容期仅接受 canonicalize 后落入配置 source/home allowlist root 的绝对路径；拒绝根外绝对路径、父目录逃逸和解析后落在 allowlist 外的 symlink。长期协议改为 root-id + relative path。
4. 默认只读；写/删需要显式 capability 或经认证会话。
5. 取消静默错误，记录 peer、operation、规范化资源标识和 condition 类型，但不泄露敏感路径内容。
6. 为连接、流和监听 socket 建立确定性 unwind/cleanup。

## 必测负例

| 场景 | 预期 |
| --- | --- |
| `#.(...)` reader payload | 不执行；协议拒绝并记录 |
| source/home allowlist 内绝对路径 | 正常工作 |
| 根外或跨未授权 root 的绝对路径 | 拒绝 |
| `../` 逃逸 | 拒绝 |
| allowlist 内 symlink 指向 allowlist 外 | 拒绝 |
| 未认证写入/删除 | 拒绝 |
| 超长、深层、截断输入 | 有界失败，不耗尽宿主资源 |
| 客户端中断 | 释放 stream/socket，无残留临时文件 |
| 测试退出 | TCP 2599 不再监听 |

## 关联计划

- [M001 宿主文件服务器加固](../modernization/initiatives/M001-host-file-server-hardening/README.md)
- [测试缺口 T001](../testing/test-gap-register.md)
