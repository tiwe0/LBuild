---
title: 测试缺口登记
status: active
owner: build-and-test
last-verified: 2026-08-31
verified-against: git:5422d69249c2104ff0ab1feff20806013cdba635
review-cycle: 30d
source-of-truth: tests
---

# 测试缺口登记

| ID | 区域 | 缺口 | 风险 | 建议层级 | 状态 |
| --- | --- | --- | --- | --- | --- |
| T001 | 文件服务器 | reader-eval、路径逃逸、未认证写删负例 | critical | L1/L4 | open |
| T002 | 编译器 | SSA/CFG verifier 负例与优化矩阵 | high | L1/L2 | open |
| T003 | LLF | 编译器/宏/目标变更触发缓存失效 | high | L2 | open |
| T004 | GC/调度 | STW、多核、线程退出、锁竞争 | high | L3/L5 | open |
| T005 | Pager | fault、writeback、低内存、回收 | high | L3/L5 | open |
| T006 | VirtIO | queue wrap、reset、IRQ/error path | high | L1/L4 | open |
| T007 | Block/FS | flush、非 512 sector、损坏镜像、卸载 | high | L3/L4 | open |
| T008 | 网络 | ARP/DHCP 超时、丢包、MTU | medium | L3/L4 | open |
| T009 | GUI | blit overlap、window/event/damage/resize | medium | L1/L3 | open |
| T010 | 平台 | 物理 ARM64、KVM/HVF 与设备矩阵 | medium | L5 | open |
| T011 | 构建 | 并发临时配置与多目标状态隔离 | high | L1/L2 | open |
| T012 | Warning | 分类基线与新增告警门禁 | high | L0/L2 | proposed |
| T013 | Debug service | Swank 默认开关、绑定、hostfwd/无转发/桥接场景与认证边界 | high | L1/L4/L5 | proposed |

缺口完成后不要删除行；更新状态并链接对应测试、initiative 或 ADR，保留演进记录。
