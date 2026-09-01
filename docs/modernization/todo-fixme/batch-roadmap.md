---
title: Lambda64 TODO/FIXME 分批路线图
status: active
owner: architecture
last-verified: 2026-08-31
verified-against: docs/modernization/todo-fixme/work-items.json
review-cycle: 7d
source-of-truth: code
---

# Lambda64 TODO/FIXME 分批路线图

本文把当前 `work-items.json` 中的 455 个工作项划分为 29 个可维护批次。批次只负责安排规格、测试和实现顺序；工作项身份、风险、测试层级和资源要求仍以冻结台账为准。

## 使用边界

- 所有批次都先补齐不可变规格和 `test-before` 证据，再取得文件所有权租约，最后进入实现。
- `critical` 和 `high` 工作项在规格缺失、台账未冻结或前置测试未锁定时不得开始批量实现。
- 批次完成不等于工作项完成。只有状态台账通过独立验证并推进到 `verified`，才能移除对应标记并计入完成数。
- 路线图按当前路径归类。文件移动或工作项拆并后，必须同时更新台账映射和本文索引。

## 当前覆盖

| 维度 | 数量 |
| --- | ---: |
| 工作项 | 455 |
| 批次 | 29 |
| `critical` | 204 |
| `high` | 229 |
| `medium` | 22 |
| 需要 cold-image 的工作项 | 349 |
| 需要 guest/integration 的工作项 | 49 |
| 需要硬件资源的工作项 | 52 |
| 仅要求 host 测试的工作项 | 5 |

其中 cold-image 数量包含 `cold-image + host + integration`、`codegen + cold-image + host` 和 `cold-image + host` 三类。guest/integration 数量包含 28 个 `guest + host + integration` 项和 21 个 `guest + host` 项。

## 推进阶段

### 阶段 0：冻结治理基线

1. 为所有 `critical`、`high` 工作项补齐可审阅规格。
2. 为每批记录聚焦测试命令、失败或覆盖证明以及所需资源。
3. 解决当前源码扫描与 bootstrap 快照之间的预冻结漂移，再执行 `freeze-ledger`。
4. 冻结后仅通过状态机和所有权租约推进工作。

### 阶段 1：快速主机闭环

优先处理 B01、B02、B04，以及 B05 中已具备聚焦主机测试的部分。目标是验证台账、租约、测试先行和独立验证流程，而不是宣称整个子系统完成。

### 阶段 2：语言、编译器与 cold-image

按 B10/B11/B15/B18 的基础契约，逐步推进 B08/B09/B12、B13/B14/B16/B17 和 B07。每批先运行聚焦 host/codegen 测试，随后才进入 cold-image；需要 integration 的批次最后统一过 guest 门槛。

### 阶段 3：监督器、存储与网络集成

先稳定 B23 的中断、PCI、DMA、分页和快照基础，再推进 B19/B20、B21/B22，最后执行 B05/B06 的完整 guest/integration 验收。涉及远程文件系统的场景应启动构建配置所要求的 fileserver；不使用远程路径的聚焦主机测试不应被 fileserver 阻塞。

### 阶段 4：真实硬件

B24–B29 必须在各自 `required-resource-ids` 对应的硬件资源上收集证据。模拟器、静态分析或 host mock 可以提前锁定契约，但不能替代硬件层级验收。

## 完整分批索引

下表的工作项列构成 455 项的完整、不重复分区。路径列列出该批实际覆盖的源码范围；依赖列表示进入批量实现或较高测试层级前的保守门槛，不替代单项规格中的具体依赖。

<!-- batch-index:start -->
| 批次 | 子系统与路径范围 | 工作项 | 风险 | 必需测试层级 | 依赖与门槛 |
| --- | --- | --- | --- | --- | --- |
| B01 | 文档契约：`Lambda64/doc/atomic-extensions.md`、`Lambda64/doc/internals/abi.md` | TF-WI-0069–0072 (4) | high | host | 先核对实现与 ABI 事实；文档检查通过后再关闭契约项。 |
| B02 | 应用与基础 GUI：`applications/*`，以及除 `gui/virgl/*` 外的 `gui/*` | TF-WI-0001–0004, TF-WI-0142–0147, TF-WI-0156–0158 (13) | medium | guest, host | 可先做 host 聚焦测试；guest 验收需要可启动镜像。B03 依赖本批稳定的 GUI 基础。 |
| B03 | VirGL：`gui/virgl/tgsi.lisp`、`gui/virgl/virgl.lisp` | TF-WI-0148–0155 (8) | medium | guest, host | 依赖 B02 的 GUI 基础；涉及虚拟 GPU 的 guest 验收还依赖 B22。 |
| B04 | 磁盘流边界：`tools/disk-stream.lisp` | TF-WI-0455 (1) | medium | host | 独立 host 契约；真实块设备行为如被规格要求，应并入 B21 集成证据。 |
| B05 | 文件系统：`file/cache.lisp`、`ext4.lisp`、`fat32.lisp`、`fs.lisp`、`http.lisp`、`local.lisp`、`remote.lisp` | TF-WI-0125–0141 (17) | high | guest, host, integration | 先用 host 测试锁定缓存和序列语义；磁盘路径依赖 B21，远程路径按场景依赖 fileserver，最终必须过 guest/integration。 |
| B06 | 网络：`net/dns.lisp`、`http-demo.lisp`、`ip.lisp`、`tcp.lisp` | TF-WI-0159–0169 (11) | high | guest, host, integration | host 协议测试先行；guest/integration 依赖 B23 的平台基础及 B29 或等效虚拟网卡路径。 |
| B07 | cold generator：`tools/cold-generator2/*` | TF-WI-0436–0454 (19) | high | cold-image, host | 与 B08、B11、B18 的对象、启动和运行时契约协调；host 验证后必须生成 cold-image。 |
| B08 | CLOS：`system/clos/*` | TF-WI-0324–0350 (27) | high | cold-image, host, integration | 依赖 B10 的语言核心和 B11/B18 的运行时基础；需 cold-image 后再做对象系统集成。 |
| B09 | 格式化：`system/format.lisp`、`xp-format.lisp`、`xp.lisp` | TF-WI-0382–0391, TF-WI-0428–0435 (18) | high | cold-image, host, integration | 依赖 B10 的读取、序列和字符语义；host 回归后进入 cold-image/integration。 |
| B10 | 语言核心：reader、loop、macro、setf、类型、数组、序列、字符串、哈希和数字逻辑 | TF-WI-0310–0317, TF-WI-0322–0323, TF-WI-0351, TF-WI-0354, TF-WI-0356–0358, TF-WI-0396–0400, TF-WI-0403–0408, TF-WI-0418–0421, TF-WI-0423 (31) | high | cold-image, host, integration | 作为 B08/B09 的前置语义批；与 B16 编译器前端保持测试矩阵一致。 |
| B11 | 启动与运行时支撑：CAS、GC、cold-start、file compiler、packages、runtime support、stream、thread pool、weak objects | TF-WI-0318–0321, TF-WI-0352–0353, TF-WI-0375–0381, TF-WI-0392–0395, TF-WI-0401, TF-WI-0411–0417, TF-WI-0422, TF-WI-0424, TF-WI-0427 (28) | high | cold-image, host, integration | 是 B07/B08 和多数系统批次的冷启动门槛；GC、线程及流变更必须隔离并分项测试。 |
| B12 | 诊断与平台工具：debug、describe、disassemble、errors、restarts、profiler、room、time、unifont | TF-WI-0355, TF-WI-0359–0374, TF-WI-0402, TF-WI-0409–0410, TF-WI-0425–0426 (22) | high | cold-image, host, integration | 依赖 B11 的启动/运行时基础；ARM64 和 x86-64 反汇编项分别与 B13/B14 对齐。 |
| B13 | ARM64 编译器后端：`compiler/backend/arm64/*` | TF-WI-0005–0020 (16) | critical | codegen, cold-image, host | 先锁定 B15 的通用 IR/CFG 契约，并与 B17 的 ARM64 运行时 ABI 对齐；必须过 codegen 和 cold-image。 |
| B14 | x86-64 编译器后端：`compiler/backend/x86-64/*` | TF-WI-0031–0041 (11) | critical | codegen, cold-image, host | 先锁定 B15 的通用 IR/CFG 契约，并与 B17 的 x86-64 运行时 ABI 对齐；必须过 codegen 和 cold-image。 |
| B15 | 通用后端：canon、CFG、dominance、instructions、passes、register allocation、SSA | TF-WI-0021–0030 (10) | critical | codegen, cold-image, host | B13/B14 的共同前置批；每项要求最小 IR/codegen 回归，不能只靠 cold-image 能启动。 |
| B16 | 编译器前端与交叉编译：`compiler/*`（不含 `backend/*`） | TF-WI-0042–0068 (27) | critical | codegen, cold-image, host | 与 B10 语言语义同步；依赖 B15 及目标后端 B13/B14 的可验证输出。 |
| B17 | 架构运行时：`runtime/*arm64*`、`runtime/*x86-64*` | TF-WI-0179–0181, TF-WI-0188–0192, TF-WI-0194–0197 (12) | critical | cold-image, host, integration | 依赖 B18 的通用对象契约，并与 B13/B14 的 ABI/codegen 双向校验。 |
| B18 | 通用运行时：allocate、function、instance、numbers、runtime、SIMD、string、struct、symbol | TF-WI-0170–0178, TF-WI-0182–0187, TF-WI-0193, TF-WI-0198–0202 (21) | critical | cold-image, host, integration | B17、B08 和 B11 的基础批；分离分配、对象布局与数值行为测试，最后统一过 cold-image/integration。 |
| B19 | ARM64 supervisor：`supervisor/arm64/*` | TF-WI-0213–0229 (17) | critical | cold-image, host, integration | 依赖 B23 的通用 supervisor 基础；与 B13/B17 的 ARM64 ABI 和中断契约一致后进入集成。 |
| B20 | x86-64 supervisor：`supervisor/x86-64/*` | TF-WI-0301–0309 (9) | critical | cold-image, host, integration | 依赖 B23 的通用 supervisor 基础；与 B14/B17 的 x86-64 ABI 和中断契约一致后进入集成。 |
| B21 | 存储 supervisor：AHCI、ATA、CD-ROM、disk、partition、store | TF-WI-0204–0212, TF-WI-0230–0248, TF-WI-0251–0252, TF-WI-0264–0266, TF-WI-0281–0283 (36) | critical | cold-image, host, integration | 依赖 B23 的 PCI/DMA/中断基础；集成通过后再作为 B05 文件系统真实后端。 |
| B22 | VirtIO supervisor：block、GPU、MMIO、PCI 和通用 virtio | TF-WI-0291–0300 (10) | critical | cold-image, host, integration | 依赖 B23 的总线、中断和 DMA 基础；虚拟块设备支撑 B05，虚拟 GPU 支撑 B03。 |
| B23 | supervisor 核心：ACPI、debug、DMA、entry、interrupts、pager、PCI、serial、snapshot、sync、thread | TF-WI-0203, TF-WI-0249–0250, TF-WI-0253–0263, TF-WI-0267–0280, TF-WI-0284–0290 (35) | critical | cold-image, host, integration | B19–B22 和硬件驱动的共同平台门槛；按中断、内存、并发、快照分小租约推进。 |
| B24 | USB OHCI：`drivers/usb/ohci.lisp` | TF-WI-0108–0120 (13) | high | hardware, host | 依赖 B23；最终证据必须来自 `hardware-usb-ohci`，host mock 不能关闭工作项。 |
| B25 | USB EHCI：`drivers/usb/ehci-intel.lisp` | TF-WI-0090–0098 (9) | high | hardware, host | 依赖 B23；最终证据必须来自 `hardware-usb-ehci-intel`。 |
| B26 | USB Mass Storage：`drivers/usb/mass-storage.lisp` | TF-WI-0100–0107 (8) | high | hardware, host | 依赖 B27 的 USB 核心和 B24/B25 中实际使用的控制器；最终证据必须来自 `hardware-usb-mass-storage`。 |
| B27 | USB 核心与 HID mouse：`drivers/usb/usb-driver.lisp`、`hid-mouse.lisp` | TF-WI-0099, TF-WI-0121–0123 (4) | high | hardware, host | 依赖 B23；按工作项分别使用 `hardware-usb-usb-driver` 和 `hardware-usb-hid-mouse`，不能合并证据。 |
| B28 | Intel 图形与音频：`drivers/intel-gma.lisp`、`intel-hda.lisp` | TF-WI-0073–0087 (15) | high | hardware, host | 依赖 B23 的 PCI/中断/DMA；分别在 `hardware-intel-gma` 和 `hardware-intel-hda` 上验收。 |
| B29 | 网卡驱动：`drivers/rtl8168.lisp`、`virtio-net.lisp` | TF-WI-0088–0089, TF-WI-0124 (3) | high | hardware, host | 依赖 B23；分别在 `hardware-rtl8168` 与 `hardware-virtio-net` 上验收，并为 B06 提供真实/虚拟网络路径。 |
<!-- batch-index:end -->

## 预冻结 P2 原型的状态

当前已有三个实现原型切片和聚焦 host 测试：

1. B05 文件缓存序列读写：TF-WI-0125、TF-WI-0126；
2. B02 BITBLT 重叠区域复制：TF-WI-0142；
3. B04 磁盘流容量边界：TF-WI-0455。

这些修改只证明“规格和聚焦测试可以落地”，属于**预冻结验证**。当前台账尚未冻结，且状态台账还不能把它们推进到 `verified`；因此本文不把这三个原型切片计为已完成批次，也不把上述四个工作项标为已验证。

## 批次完成门槛

每个批次关闭前必须逐项满足：

1. 台账已冻结，工作项规格与 occurrence 映射未漂移；
2. 所有目标文件受有效、无重叠的 ownership lease 保护；
3. `test-before` 证据存在，且覆盖成功、边界和失败行为；
4. 必需测试层级全部通过，硬件项使用匹配的 `required-resource-ids`；
5. 实现者之外的验证者检查证据并推进状态；
6. `python3 scripts/check-todo-fixme.py --verify` 与快速回归门禁通过；
7. 对应标记只在工作项达到 `verified` 后移除。

## 维护自检

下面的只读命令解析本文批次索引中的 ID/范围，并与 `work-items.json` 比较，验证 29 个批次恰好覆盖 455 个工作项：

```sh
python3 - <<'PY'
import json
import pathlib
import re

base = pathlib.Path("docs/modernization/todo-fixme")
text = (base / "batch-roadmap.md").read_text()
index = text.split("<!-- batch-index:start -->", 1)[1].split(
    "<!-- batch-index:end -->", 1
)[0]

seen = []
for start, end in re.findall(r"TF-WI-(\d{4})(?:–(?:TF-WI-)?(\d{4}))?", index):
    first = int(start)
    last = int(end or start)
    seen.extend(f"TF-WI-{number:04d}" for number in range(first, last + 1))

expected = {
    item["id"]
    for item in json.loads((base / "work-items.json").read_text())["work-items"]
}
assert len(re.findall(r"^\| B\d{2} \|", index, re.MULTILINE)) == 29
assert len(seen) == len(set(seen)) == 455
assert set(seen) == expected
print("batch-roadmap coverage: 29 batches / 455 work items")
PY
```

此命令只验证路线图覆盖，不替代台账冻结、状态机验证或任何实现测试。
