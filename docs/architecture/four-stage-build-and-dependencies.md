---
title: 四阶段构建与依赖加载
status: active
owner: build-and-test
last-verified: 2026-09-11
verified-against: git:1f07257d782b742bac5c53a4bf1d90446f83c9aa
review-cycle: 90d
source-of-truth: code
---

# 四阶段构建与依赖加载

系统从源码到可用桌面要经过四个界限分明的阶段，每一阶段的产物载体不同，失败形态也不同。
`docs/architecture/build-and-boot-lifecycle.md` 描述了整体时序；本文补充**冷/暖切分**与
**第四阶段的运行时依赖加载**，后者是目前最不标准化、最值得先理清的部分。

## 阶段总览

| 阶段 | 执行者 | 输入 | 产物 | 失败形态 |
| --- | --- | --- | --- | --- |
| 1. 宿主交叉编译 | SBCL | `.lisp` | `lambda64.image` | 宿主异常，有完整回溯 |
| 2. 冷启动 | 客户机 supervisor | 镜像内冷对象 | `Cold load complete.` | panic，但 `format` 尚不可用 |
| 3. 暖模块 | 客户机 | 镜像内嵌 `.llf` | `Hello, world.` | panic，`format` 可用 |
| 4. 运行时依赖 | 客户机 + 宿主文件服务 | `home/` 子模块 | 桌面/GUI/应用 | 网络或路径错误 |

## 阶段一：宿主交叉编译

`make cold-image` → `build-cold-image.lisp`：

1. quicklisp 加载宿主依赖（nibbles、cl-ppcre、iterate、alexandria、closer-mop、
   trivial-gray-streams），`make deps` 之后为本地缓存，不再联网。
2. `asdf:load-system :lispos` 把交叉编译器与 cold-generator 装入 SBCL。
3. `cold-generator:set-up-cross-compiler :architecture :arm64` 建立宿主/目标环境。
4. 编译并生成镜像。

**冷/暖切分**在 `Lambda64/tools/cold-generator2/cold-generator.lisp`：

- 冷源文件直接序列化为镜像中的对象。
- `*warm-source-files*` 编译为 `.llf` 后由 `save-warm-files` **嵌入镜像**，运行时通过
  `sys.int::*warm-llf-files*` 取用。**暖模块不走网络**。

## 阶段二与三：冷启动与暖模块

`Lambda64/system/cold-start.lisp` 中 `initialize-lisp` 的关键序列：

```
(gc :full t)
(write-line "Cold load complete.")
(mezzano.supervisor:snapshot)          ; 快照 #1
(write-line "Loading warm modules.")
  ... 逐个 load-llf *warm-llf-files* ...
(gc) (room)
(mezzano.supervisor:snapshot)          ; 快照 #2
(format t "Hello, world.~%Cold start took ...")
```

两个常见误解，值得写下来：

- **`Cold load complete.` 在暖模块加载之前**，不是启动完成的标志。
- **`snapshot` 调用返回后写回仍在后台进行**。CoW 机制让主线程不必等待脏页写完，
  所以"还有几万页待写回"与"已经进入下一阶段"可以同时为真。

`initialize-lisp` 的终点是 `Hello, world.` 加冷启动耗时统计。到这一步为止，**全程不需要网络**。

## 阶段四：运行时依赖加载

这是目前最不标准化的一段，入口在 `Lambda64/ipl.lisp`：

```lisp
(mezzano.file-system.remote:add-remote-file-host :remote sys.int::*file-server-host-ip*)
(setf *default-pathname-defaults* (pathname *mezzano-source-path*))
(setf mezzano.file-system::*home-directory* (pathname *home-directory-path*))
```

### 传输层

- **不是 HTTP**。是 `Lambda64/file-server/server.lisp` 实现的自定义 TCP 协议，
  默认端口 **2599**，命令以 s-表达式编码。
- 宿主端由 `run-file-server.lisp` 启动（`make run-file-server`）。
- 客户机侧注册为名为 `REMOTE` 的文件系统主机，此后 `REMOTE:/path/...` 即可当作普通路径使用。

### 配置注入

三个变量定义在 `Lambda64/config.lisp`，但**工作区中看到的永远是占位符模板**：

```lisp
(defparameter *file-server-host-ip* "192.168.0.123")
(defparameter *mezzano-source-path* "REMOTE:/Full/path/to/Lambda64/")
(defparameter *home-directory-path* "REMOTE:/Full/path/to/home/directory/")
```

`scripts/with-temporary-config.sh` 在构建期间临时写入真实值、构建结束后还原。真实值来自
根 `Makefile`：`FILE_SERVER_IP`（默认 `10.0.2.2`，即 QEMU user-mode NAT 网关，
从客户机看就是宿主）、源码树路径与 `home/` 路径。

因此有三条推论：

1. **文件服务地址是构建期烘死的**，换地址必须重新构建镜像。
2. **`-netdev user` 是 `10.0.2.2` 生效的前提**。改用 bridge/tap 网络时该地址不再指向宿主，
   必须同时改 `FILE_SERVER_IP` 并重新构建。
3. **DHCP 可以在运行时覆盖它**：`Lambda64/net/dhcp.lisp` 在租约携带 `mezzano-server`
   选项时会改写 `*file-server-host-ip*`。QEMU 内置 DHCP 不发该选项，但真实网络环境下需要留意。

### 依赖本身

`home/` 下的库是 **git submodule**，由 `make deps` 递归拉取，`make asdf` 单独构建
`home/asdf`。目前有二十余个，覆盖 ASDF、alexandria、babel、zpb-ttf、cl-jpeg、chipz、
slime、med 等。

**标准化时需要注意的现状**：

- 没有版本解析，没有依赖清单——版本即 submodule 指向的 commit。
- 没有构建产物缓存：客户机每次按需从宿主读源码并编译。
- ASDF 自身也是被管理的依赖之一，存在先有鸡还是先有蛋的次序要求。
- 宿主与客户机共享同一份 `home/` 目录，因此宿主侧的未提交改动会**直接影响客户机行为**，
  这在调试时方便，在复现问题时是风险。

## 排障要点

- 阶段二/三**不需要**文件服务。若在 `Hello, world.` 之前失败，不要去查网络。
- 阶段四失败时先确认三件事：宿主 2599 是否在监听；QEMU 是否使用 `-netdev user`；
  镜像烘入的 `FILE_SERVER_IP` 是否与当前网络拓扑一致。
- 每个阶段可用的诊断能力不同。阶段二连 `format` 都没有，错误可能表现为
  `Undefined function`；阶段三之后错误信息质量显著提升。相关约束见
  [不可分配上下文](../development/allocation-forbidden-contexts.md)。
