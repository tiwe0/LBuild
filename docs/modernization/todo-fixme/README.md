---
title: Lambda64 TODO/FIXME 完成台账
status: active
owner: architecture
last-verified: 2026-08-31
verified-against: git:5422d69249c2104ff0ab1feff20806013cdba635
review-cycle: 7d
source-of-truth: code
---

# Lambda64 TODO/FIXME 完成台账

此目录是 Lambda64 遗留项完成工作的受版本控制事实源：用**原始标记出现记录**确保没有遗漏，用**逻辑工作项**管理真实实现和验收。不能通过移动、改写或删除标记来关闭工作项。

## 当前基线

| 层级 | 数量 | 含义 |
| --- | ---: | --- |
| 原始出现记录 | 484 | 当前基线中的全部大小写不敏感 `TODO`/`FIXME` 命中。 |
| 可执行闭环范围 | 455 | 451 条第一方源码记录加 4 条文档契约记录。 |
| 数据误匹配 | 29 | 仅 `UnicodeData.txt` 中逐条哈希锁定的正式字符名称。 |
| 初始工作项与映射 | 455 / 455 | 每个可执行出现记录均已有可审阅的初始工作项和映射；高风险项在补齐冻结规格前不得进入实现。 |

这个初始一对一映射是防漏项下限，不是用命中数代替行为验收。后续只有在规格、回归测试、实现和独立验证都齐全后，状态台账才可推进到 `verified`。

## 状态机

1. `bootstrap` 生成 occurrence、Unicode 数据白名单和源码基线；
2. 人工完成不可变工作项与映射后执行 `freeze-ledger`；
3. 实现期间只推进可变状态台账，`--verify` 严格只读。

权威入口：

```sh
python3 scripts/check-todo-fixme.py --verify
make todo-fixme-check
```

在 baseline 冻结前，上述验证会故意失败；这是防止未登记实现提前被当作完成的门禁。

## 文件

- `occurrences.json`：每个原始 TODO/FIXME 出现记录。
- `work-items.json`：冻结的逻辑行为契约。
- `work-item-status.json`：可变实现/测试状态及证据引用。
- `occurrence-work-items.json`：两层台账的多对多映射。
- `baseline-snapshot.json`：扫描、源码和治理冻结哈希。
- `unicode-allowlist.json`：Unicode 名称数据中的精确误匹配。
- `ownership-leases.json`：文件所有权与工作树漂移证据。
- `hardware-resources.json`：x86、硬件和模拟器验证资源。
- `schema/`：各 JSON 文件的格式约束。

高风险条目的不可变规格位于 `specs/`；真实硬件测试证据位于 `evidence/`。二者均会被验证器检查。
