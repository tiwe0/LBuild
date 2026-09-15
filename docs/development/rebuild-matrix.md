---
title: 改了什么需要重建镜像
status: active
owner: maintainers
last-verified: 2026-09-15
verified-against: git:59f08f9f9c46ca456d6123b2d59632aa28dbb31f
review-cycle: 180d
source-of-truth: code
---

# 改了什么需要重建镜像

改动落在哪一层,决定了你要付多少时间:从**秒级**(在运行的系统里重定义)到**分钟级**
(重启重编第四阶段)到**小时级**(重建冷镜像并完整冷引导一次)。

本文的分类不是约定俗成,而是可以从代码里读出来的:
`Lambda64/tools/cold-generator2/cold-generator.lisp` 用四份清单定义了整条边界。

## 判定表

| 改动位置 | 需要 | 代价 |
| --- | --- | --- |
| 已在运行系统中的任意函数、方法、类 | SWANK 重定义 | 秒级,不重启 |
| `*warm-source-files*` / `*source-files*` / `*supervisor-source-files*` 中的文件 | **重建冷镜像 + 冷引导** | 构建约 90 秒,冷引导数小时 |
| `*cross-source-files*` 中的文件 | **重建冷镜像 + 冷引导** | 同上 |
| IPL 第四阶段 `cal` 的 46 个文件 | 删除对应 `.llf` 后重启 | 单文件重编,分钟级 |
| `home/` 下的第三方库 | 删除 `home/.cache` 中对应产物后重启 | 按库大小,分钟级 |
| `ipl.lisp` 自身 | 重启(它是 `SYS:SOURCE;` 下的脚本,每次引导重读) | 一次引导 |
| `Makefile` / `scripts/` / 文档 | 无 | 即时 |

## 四份权威清单

`cold-generator.lisp` 中:

| 清单 | 数量 | 含义 |
| --- | --- | --- |
| `*cross-source-files*` | 46 | 宿主侧交叉编译环境。决定冷生成器**怎么编** |
| `*supervisor-source-files*` | 68 | supervisor、驱动、分页、调度,直接进冷镜像 |
| `*source-files*` | 39 | 运行时与系统核心,直接进冷镜像 |
| `*warm-source-files*` | 120 | 冷生成时编成 `.llf`,**烤进镜像**(见该文件 `;; Bake the compiled files directly into the image.`) |

前三类合计 227 个唯一文件。**`*warm-source-files*` 名字里的 warm 容易误解**——它不是
"引导时从源码加载",而是"预编译后随镜像一起发货"。改这里同样要重建。

与 IPL 第四阶段 `cal` 的 46 个文件**零重叠**,边界是干净的。

## 第四阶段的 46 个文件为什么在那里

分三类,只有第三类是可以重新权衡的:

**一、依赖第三方 ASDF 库,技术上不可能提前。** 冷生成器引用 `home/` 的次数是 0,
它的世界里没有 ASDF 也没有这些库。

- `gui/font.lisp` → `zpb-ttf:` `paths-ttf:`
- `gui/image.lisp` → `png-read:` `jpeg:`

`ipl.lisp` 先 `(require ...)` 15 个 ASDF 系统,才能 `cal` 这些文件。

**二、传递依赖上面那批。** 自己不碰第三方库,但要用 GUI,而 GUI 要字体:

- `applications/*.lisp`(9 个)→ `mezzano.gui.compositor` / `mezzano.gui.widgets`
- `drivers/intel-gma.lisp` → `mezzano.gui.compositor`

**三、引导不需要,纯属选择。** 这一类**技术上完全可以烤进镜像**:

- `file/ext4.lisp` 只依赖 `mezzano.file-system` / `mezzano.internals` /
  `mezzano.supervisor`,全是已烤进去的包
- 同类还有 `file/http.lisp`、`drivers/sound.lisp`、三个反汇编器、`system/lldb.lisp`

代价是每次冷引导都要重编一遍(`ext4.lisp` 单文件约二十分钟),收益是冷镜像与冷构建
保持小而快。**如果冷引导时间成为瓶颈,把第三类移进 `*warm-source-files*` 是可行改动**,
不受架构约束。

## 各层的具体操作

### 在运行的系统里改(最快)

系统起来后 SWANK 监听转发端口,直接重定义:

```
M-x slime-connect RET 127.0.0.1 RET 4005
```

函数、方法、类都能就地替换。改 supervisor 里的东西也能改,但**新定义只活到下次重启**,
而且底层代码在重定义瞬间可能正被执行——改分配器或中断路径时要清楚这一点。

### 重编第四阶段的单个文件

第四阶段的产物是 `.llf`。删掉对应文件再重启,系统会重新编译它:

```sh
rm Lambda64/gui/compositor.llf      # 源码旁的产物
rm -rf home/.cache/common-lisp      # ASDF 管理的库产物
```

两处位置不同:`sys:source;` 下的文件产物落在源码旁,ASDF 系统的落在 `home/.cache/`。

### 重建冷镜像

```sh
make cold-image
```

约 90 秒。但**随后的冷引导要数小时**——第四阶段要把整棵依赖树重编一遍。已有的
`.llf` 会被复用,所以第二次冷引导远快于第一次。

## 快照恢复

快照恢复可用:整个运行中的系统连同线程、桌面、网络栈从镜像恢复,不编译任何东西。

实测(2026-09-15,同一镜像):

| | 冷引导 | 快照恢复 |
| --- | --- | --- |
| 耗时 | 4 分 52 秒 | **56 秒** |
| 串口日志 | 67,012 行 | 395 行 |
| 重新编译 | 全部第四阶段 | **无** |

引导时串口会打印走了哪条路径,\`TRACE boot-first-run\` 或 \`TRACE boot-resume\`。**判断"这次是不是恢复"以这一行为准**,不要依据引导耗时或其他 \`BOOT-MARK\` 标记——后者在引导早期不产出。

### 修好它用了两层

两个缺陷叠在一起,各自都足以让恢复失效:

1. **分支不可达。** 一次 WIP 提交把原分支条件从 \`first-run-p\` 取反为 \`(not first-run-p)\`,与前一分支构成穷尽,真正的恢复分支成为死代码。每次恢复都重跑 \`INITIALIZE-LISP\`,而它末尾会 \`makunbound\` 冷生成器提供的 obarray,于是第二次引导必 panic \`Unbound symbol *INITIAL-CREF-OBARRAY*\`。
2. **分支永远选不中。** \`*boot-id*\` 同时承担两个互相矛盾的职责:DMA 缓冲区用它判断"引导世代"(要求每次不同),而首次引导判定用它是否等于冷哨兵(要求首次引导保持哨兵值)。首次引导把它设为哨兵、随快照存盘,下次读到哨兵又判为首次引导。现已拆出独立的 \`*cold-bootstrap-completed*\`,设在 \`INITIALIZE-LISP\` 消费完 obarray 的那一行——即"重跑冷路径会致命"的精确时刻。

### 设备需要每次引导重新认领

快照恢复的是软件状态。硬件不是:FDT 扫描每次引导都产生全新的、未认领的设备对象。

- 走驱动注册表的设备(网卡)由 \`virtio-late-probe\` 自动重新认领
- GPU 与输入设备走内建分派,原本只有 IPL 调用一次——**而恢复不跑 IPL**

症状是系统看似正常(线程、合成器都在)但屏幕显示 \`Display output is not active.\`,键鼠无响应。现由 IPL 注册的 \`:early\` boot hook 每次引导重新认领,顺序必须早于 \`detect-virtio-input-devices\`。

**验证显示是否真的工作,用 QEMU monitor 抓屏,不要靠线程是否存在推断:**

\`\`\`sh
./scripts/boot-image.sh --monitor /tmp/mon.sock ...
# 另一个终端,经 unix socket 发送(只发只读命令,绝不要发 quit):
#   screendump /tmp/screen.ppm
\`\`\`

### 已知遗留

- **快照慢**,两个独立因素相乘:非增量(ARM64 上脏页追踪被关闭,每次全量约 645 MB)与每页一次同步磁盘往返(约 387 次/秒,645 MB 需约 7 分钟)。详见债务登记 D025——其中同步往返那项明显更易改善。

## 直接引导已有镜像

```sh
make boot                                   # 默认 lambda64.image,自动选择加速器
./scripts/boot-image.sh --help              # 全部选项

# 只读试验:读备份、写入丢弃、换端口,不影响正在运行的实例
./scripts/boot-image.sh --image backups/xxx.image --swank-port 4006 --snapshot
```

`--snapshot` 让 QEMU 把写入放进临时覆盖层,镜像不被修改——**验证引导改动时应当默认
带上它**,否则一次失败的引导可能让镜像进入不可用状态。

需要 guest 编译东西时(改了第四阶段文件、或删了 `.llf`),仍要先
`make run-file-server`。

## 备份

宿主侧克隆之前,先让 guest 自己落盘,否则拿到的只是崩溃一致的瞬间:

```lisp
(mezzano.supervisor:snapshot)   ; 经 SWANK 调用,返回后镜像是完整可恢复状态
```

```sh
cp -c lambda64.image backups/lambda64-$(date +%Y%m%d-%H%M).image
```

APFS 上 `cp -c` 是写时复制克隆,耗时约 4 毫秒且初始不占额外空间。`/backups/` 已在
`.gitignore` 中。
