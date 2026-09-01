---
title: GUI 与应用
status: active
owner: gui
last-verified: 2026-08-31
verified-against: git:5422d69249c2104ff0ab1feff20806013cdba635
review-cycle: 90d
source-of-truth: code
---

# GUI 与应用

## 结构

GUI 由 surface/colour/blit/font/image 基础层、compositor、窗口事件、桌面和应用组成。包边界定义在 `Lambda64/gui/package.lisp`，合成与 damage 处理集中在 `Lambda64/gui/compositor.lisp`，桌面入口位于 `Lambda64/gui/desktop.lisp`。

事件链大致为：设备输入 → compositor mailbox → window FIFO → 应用事件循环 → 绘制 surface → damage/recompose → framebuffer。

## 关键实现

- 合成与 damage：`Lambda64/gui/compositor.lisp:1311-1385`
- 桌面线程：`Lambda64/gui/desktop.lisp:223-260`
- blit：`Lambda64/gui/blit.lisp`
- 应用/第三方装载：`Lambda64/tools/load-sources.lisp:37-84`
- Lisp/LLF loader：`Lambda64/system/load.lisp:455-526`
- IPL 启动桌面：`Lambda64/ipl.lisp:269-281`

## 风险

- 缺少窗口生命周期、输入路由、damage、resize 和渲染结果的自动化测试。
- compositor 与桌面依赖全局线程/对象，应用退出和资源释放契约不统一。
- 桌面图标配置使用字符串形式再 `read-from-string`/求值，数据与代码边界不清晰。
- 第三方集成会直接修改包内部实现，升级难以隔离。
- 重叠区域 bitblt 的复制方向/别名行为需要明确测试。

## 现代化顺序

1. 为 surface/blit 编写宿主可运行的纯函数测试，覆盖重叠、裁剪、alpha 和格式转换。
2. 固定窗口/事件/damage/resize 的 Guest 契约。
3. 用结构化 app descriptor 替代字符串形式配置。
4. 抽取 app/window session 生命周期，统一创建、退出和资源释放。
5. 建立稳定 compositor API，再隔离第三方扩展点。

不要首先大改 CLOS/package 基础层；它的影响面广且当前测试不足。
