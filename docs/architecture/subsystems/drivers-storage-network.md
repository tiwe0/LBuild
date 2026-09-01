---
title: 驱动、存储与网络
status: active
owner: io-platform
last-verified: 2026-08-31
verified-against: git:5422d69249c2104ff0ab1feff20806013cdba635
review-cycle: 90d
source-of-truth: code
---

# 驱动、存储与网络

## 当前结构

- PCI 枚举/绑定：`Lambda64/supervisor/pci.lisp:455-613`
- VirtIO 队列/中断：`Lambda64/supervisor/virtio.lisp:398-522`
- VirtIO MMIO：`Lambda64/supervisor/virtio-mmio.lisp:116-141`
- VirtIO block：`Lambda64/supervisor/virtio-block.lisp:38-146`
- 磁盘抽象：`Lambda64/disk/disk.lisp:46-110`
- 文件系统 host/mount：`Lambda64/file/fs.lisp:797-866`
- 网卡抽象：`Lambda64/drivers/network-card.lisp:46-115`
- VirtIO net：`Lambda64/drivers/virtio-net.lisp:260-357`
- 网络配置：`Lambda64/net/network-setup.lisp:68-155`

当前设备层以 CLOS generic、直接 MMIO/PIO、DMA buffer 和中断回调为主。QEMU 集成主要证明 VirtIO 路径，不证明所有物理设备、IOMMU 或异常设备行为。

## 已知限制

- VirtIO MMIO 仅处理 legacy version 1，IRQ 路径有明确 FIXME。
- VirtIO block 固定 512-byte sector、单队列，flush 尚未完成。
- 缺少统一 DMA mask、bounce buffer、IOMMU 和资源释放模型。
- 网络配置、协议状态与设备驱动边界不够清晰；ARP 过期机制被禁用。
- 文件系统 mount 生命周期和设备热插拔缺少统一管理器。

## 目标分层

1. 设备/总线发现层：只产生标准化资源描述。
2. DMA/IRQ 层：统一映射、同步、释放和错误语义。
3. 驱动层：设备状态机，不直接承担高层策略。
4. block/network 核心层：队列、超时、取消和统计。
5. 文件系统/网络配置层：面向用户策略与生命周期。

## 现代化顺序

先为现有 VirtIO 路径增加 host-pure 与 QEMU 契约测试，再抽取 device/bus/resource API；随后治理 DMA/IRQ，最后分别演进异步 block I/O、网络栈和 mount manager。不要把文件服务器安全协议改造并入 Guest 网络栈重写。

## 测试缺口

- 描述符环 wrap、队列满、设备复位、错误中断。
- 非 512 sector、flush/barrier、I/O 超时与取消。
- DHCP/ARP 超时、丢包、重复包、MTU 边界。
- ext4/FAT 损坏镜像、只读/写入语义和卸载。
