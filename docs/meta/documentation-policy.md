---
title: 文档治理策略
status: active
owner: maintainers
last-verified: 2026-08-31
verified-against: git:5422d69249c2104ff0ab1feff20806013cdba635
review-cycle: 90d
source-of-truth: documentation
---

# 文档治理策略

## 1. 权威顺序

发生冲突时按以下顺序判断：

1. 可重复执行的测试与运行证据；
2. 当前提交上的实现代码和构建脚本；
3. 已接受且未被取代的 ADR；
4. `docs/` 下标记为 `active` 的文档；
5. `Lambda64/doc/`、README、Issue 或注释等历史材料。

文档不能替代代码验证，也不能把一次运行快照表述为跨版本保证。

## 2. 元数据

非索引文档使用以下前置字段：

```yaml
---
title: 文档标题
status: draft | active | historical | deprecated
owner: 稳定的组件或维护角色
last-verified: YYYY-MM-DD
verified-against: git:<commit>
review-cycle: 90d
source-of-truth: code | tests | documentation | external
---
```

- `last-verified` 表示最后一次对照实现或执行证据复核，不是编辑时间。
- `owner` 使用组件/角色，不绑定临时个人。
- 超过复审周期的文档仍可阅读，但必须被视为可能过期。
- Initiative 另用 `initiative-status`，ADR 另用 `decision-status`；不要借用文档的 `status` 表示工作流状态。

## 3. 目录职责

- `architecture/` 描述当前系统与稳定边界，不承载愿景清单。
- `modernization/` 描述从当前状态到目标状态的阶段、风险与验收。
- `decisions/` 只记录需要长期保留上下文的取舍，不写流水账。
- `testing/` 描述可以复现的验证契约；单次结果放在测试产物中。
- `reference/` 放术语、命令和历史映射，不复制实现说明。

## 4. 生命周期

1. 新文档以 `draft` 开始。
2. 对照代码/测试验证且链接检查通过后改为 `active`。
3. 不再适用但仍有历史价值时改为 `historical`。
4. 被明确替代时改为 `deprecated`，并链接替代文档或 ADR。

## 5. 完成定义

文档变更至少通过：

- `make docs-check`；
- 相对 Markdown 链接可解析；
- 所有引用的仓库路径存在；
- `git diff --check` 无空白错误；
- 与改动相关的索引页已更新；
- 若描述实现完成，附实际测试或运行证据。

## 6. 历史文档处理

不批量搬运 `Lambda64/doc/`。先在 [历史文档映射](../reference/legacy-doc-map.md) 中标记它的主题、可信度、替代页和待验证点，再按需吸收仍有效的内容。这样可保留历史上下文，避免复制后形成两个事实源。
