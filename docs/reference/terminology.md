---
title: 术语表
status: active
owner: architecture
last-verified: 2026-08-31
verified-against: git:5422d69249c2104ff0ab1feff20806013cdba635
review-cycle: 180d
source-of-truth: code
---

# 术语表

| 术语 | 含义 |
| --- | --- |
| LBuild | 仓库根部的宿主构建、镜像和测试编排工程 |
| Lambda64 | 当前主要系统源码目录；仍保留大量 Mezzano 历史 package/符号名称 |
| Host | 执行 SBCL、构建脚本、文件服务器和 QEMU 的开发/CI 系统 |
| Guest | 由 QEMU 启动的 Lambda64 目标系统 |
| Supervisor | Guest 早期启动、线程、分页、异常和低层设备核心 |
| LLF | 交叉编译器与 cold generator 之间的目标对象/命令流格式 |
| Cold build | 不依赖已有可疑缓存/镜像的完整目标镜像生成流程 |
| IPL | 镜像启动后的高层系统加载与初始化阶段 |
| Serial oracle | 根据 Guest 串口协议、fatal marker 和超时作出通过/失败判断的宿主工具 |
| Initiative | 有明确范围、风险、步骤和验收矩阵的现代化工作包 |
| Gate | 下一阶段开始前必须满足的阻断条件 |
