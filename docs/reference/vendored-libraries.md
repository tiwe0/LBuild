---
title: 归档的第三方库
status: active
owner: maintainers
last-verified: 2026-09-14
verified-against: git:ef44cb01ef41eea6b8ecd1487ec043f101aa46da
review-cycle: 180d
source-of-truth: documentation
---

# 归档的第三方库

`home/` 下的库曾经是 git 子模块,现在作为**普通文件直接纳入本仓库**。

## 为什么

子模块把第三方仓库的状态变成了本树的外部依赖。上游强推、改名、删仓,或者只是
在一次 `--recursive` 拉取里悄悄前进一个提交,都会让本树的构建结果发生我们没有
批准的变化 —— 而这种变化在 CI 上表现为"昨天还好好的今天挂了",排查成本极高。
把代码收进来之后,本树的构建输入完全由本树的提交图决定。

代价是**不再能用 `git submodule update` 拿上游更新**。这是有意的取舍:更新改成
显式动作,见下文。

## 这不是纯粹的镜像

至少有一处本地修改是必需的,不能靠"重新拉一次上游"得到:

- `home/med/main.lisp` —— `mezzano.gui.compositor:get-window-by-kind` 在本树中
  已改为异步、返回 mailbox(见 `Lambda64/gui/compositor.lisp`),调用方必须
  `mezzano.sync:mailbox-receive`。这是我们单方面改动 API 造成的,补丁理应由本树
  承担。

所以用上游版本覆盖 `home/` 下任何目录之前,先确认要覆盖的目录有没有本地改动。

## 字节原样保存

`home/.gitattributes` 设置了 `* -text`,关闭全部行尾转换。仓库的
`core.autocrlf=input` 会在入库时剥掉 CR,而这里有文件的 CRLF 就是被测对象 ——
`home/flexi-streams/test/` 下的 `*_crlf.txt` 夹具正是用来验证 CRLF 解码的,
`home/cl-pdf/afm/` 下的字体度量数据同理。归一化会让它们静默失效。

## 如何更新某个库

没有自动流程,也不该有。手工步骤:

```sh
git clone <上游 URL> /tmp/lib && git -C /tmp/lib checkout <目标提交>
diff -ru home/<lib> /tmp/lib          # 先看清本地有没有改动会被覆盖
rsync -a --delete --exclude .git /tmp/lib/ home/<lib>/
git add home/<lib> && make test-fast
```

然后更新下表中的提交号,并在提交信息里写明升级原因。

## 归档清单

下表记录每个目录的来源与冻结时所在的提交。这是子模块指针唯一值得保留的信息,
失去它就无法判断本地代码相对上游差了多少。

### 顶层

| 目录 | 上游 | 固定提交 |
| --- | --- | --- |
| `home/alexandria` | https://github.com/froggey/alexandria.git | `afaf1a16210818be73d182920d6adf7a00bbcf00` |
| `home/ansi-test` | https://gitlab.common-lisp.net/ansi-test/ansi-test.git | `a1107c9564833680c72946f1cd87c9c3bbe0de5a` |
| `home/asdf` | https://github.com/froggey/asdf.git | `d12f9580f283fc6c85edb59cb3bd2f58312836bd` |
| `home/babel` | https://github.com/cl-babel/babel | `6aaea300d55dcddedc1d584114605d92249570e5` |
| `home/binary-data` | https://github.com/gigamonkey/monkeylib-binary-data.git | `22e908976d7f3e2318b7168909f911b4a00963ee` |
| `home/bitio` | https://github.com/psilord/bitio.git | `b138b755c48e5f1feab63dbb8e25504394ab90d2` |
| `home/bordeaux-threads` | https://github.com/froggey/bordeaux-threads.git | `3749b9a65f57036f31a0794ed3a4ba2e61e5d56a` |
| `home/chipz` | https://github.com/froggey/chipz | `277a3a7026d9dd5ffe5d3c05f80998813d8bd152` |
| `home/cl-fad` | https://github.com/froggey/cl-fad.git | `6cbb1d78637e2b71abece31a7a3540269ddeab51` |
| `home/cl-jpeg` | https://github.com/sharplispers/cl-jpeg.git | `319a8f347e4bc590e0ad9e66624dedbf324bcf98` |
| `home/cl-pdf` | https://github.com/mbattyani/cl-pdf.git | `7796456e62efe7a8efc51a707a285a69fedc717b` |
| `home/cl-ppcre` | https://github.com/edicl/cl-ppcre.git | `1ca0cd9ca0d161acd49c463d6cb5fff897596e2f` |
| `home/cl-riff` | https://github.com/RobBlackwell/cl-riff.git | `536eae2c852ab2efb4e272bb89f1b1dc70cd38f4` |
| `home/cl-tga` | https://github.com/fisxoj/cl-tga.git | `4dc2f7b8a259b9360862306640a07a23d4afaacc` |
| `home/cl-vectors` | https://github.com/fjolliton/cl-vectors.git | `0fda45f84b5cc35fb15e387f20a6b66fa8941a02` |
| `home/cl-video` | https://github.com/varjagg/cl-video.git | `eb5fbea3592b74cdb0458b7bcdeb70f0423a8183` |
| `home/cl-wav` | https://github.com/RobBlackwell/cl-wav.git | `c236439204221ce0d2057493d70c8d7fe9d3e57e` |
| `home/closer-mop` | https://github.com/froggey/closer-mop.git | `b6d09922c2916e323c8a691b602b62aa6fd9941a` |
| `home/deflate` | https://github.com/pmai/Deflate.git | `a1677371c44aac4fd8bd2fbdfd4a1aa52e725d5e` |
| `home/fast-io` | https://github.com/rpav/fast-io.git | `dc3a71db7e9b756a88781ae9c342fe9d4bbab51c` |
| `home/flexi-streams` | https://github.com/edicl/flexi-streams.git | `c2be8607b2e1286ec9ba00eb529fd79983e8648d` |
| `home/flexichain` | https://github.com/robert-strandh/Flexichain.git | `dec48631b560fc018f2e1ebcae751fc81cb7d37c` |
| `home/ieee-floats` | https://github.com/marijnh/ieee-floats.git | `566b51a005e81ff618554b9b2f0b795d3b29398d` |
| `home/mcclim` | https://github.com/froggey/McCLIM.git | `75d43b06312b82690a05e6b6b4e733f9a3cb6e28` |
| `home/med` | https://github.com/froggey/med | `f2205b9f94feb34b8e5146e9e24227a6dd329161` |
| `home/nibbles` | https://github.com/froggey/nibbles.git | `8ae00d8cc0232ced2d9141a35b153f3786ae4dc0` |
| `home/opticl` | https://github.com/froggey/opticl.git | `38975feca07afa265d0a37f0fc33214afc39529d` |
| `home/opticl-core` | https://github.com/slyrus/opticl-core.git | `b7cd13d26df6b824b216fbc360dc27bfadf04999` |
| `home/parsley` | https://github.com/froggey/parsley | `6f92ebcdde41c49585053d8b9eddf000a9041583` |
| `home/png-read` | https://github.com/Ramarren/png-read | `991ba7426f9a1fef97626b21f3e088206656a2e5` |
| `home/pngload` | https://github.com/froggey/pngload.git | `76fc3adc7aa032e2f5a67ce77bc4c32939b88cd4` |
| `home/quicklisp-client` | https://github.com/froggey/quicklisp-client.git | `84112c060928f54d3323a585467b9d73bf465b1a` |
| `home/retrospectiff` | https://github.com/slyrus/retrospectiff.git | `c2a69d77d5010f8cdd9045b3e36a08a73da5d321` |
| `home/salza2` | https://github.com/xach/salza2.git | `dc8cda846c36b0b0b34601fbda207bc2dafa014d` |
| `home/skippy` | https://github.com/xach/skippy.git | `cbdb64921daa5352e75a908ba5aff91076a99dc6` |
| `home/slime` | https://github.com/froggey/slime | `f81ab630423d9deb01d62464682ee0a21aab6624` |
| `home/spatial-trees` | https://github.com/rpav/spatial-trees.git | `81fdad0a0bf109c80a53cc96eca2e093823400ba` |
| `home/split-sequence` | https://github.com/sharplispers/split-sequence.git | `b8ee7ee6e0c3bfdfad9b111365a2a39563851bb0` |
| `home/static-vectors` | https://github.com/fittestbits/static-vectors.git | `468cad1aad93828ee59eb90c7c1c131baf07fb4a` |
| `home/trivial-features` | https://github.com/froggey/trivial-features | `6937cac7ecf0f5742c50ea0ca6e6025f160a4ddf` |
| `home/trivial-garbage` | https://github.com/froggey/trivial-garbage.git | `d3e470cb2385f7564147367452cb6237d3bd9818` |
| `home/trivial-gray-streams` | https://github.com/froggey/trivial-gray-streams.git | `d6094358def8ca9db3e1d5828a8442504163e71e` |
| `home/zpb-ttf` | https://github.com/froggey/zpb-ttf | `a5ba82d733ecd4d2c16790df31070814a3bd8ff7` |
| `home/zpng` | https://github.com/xach/zpng.git | `7a65364de5e575639f9da4ccb0232bba78fb61cd` |

### `home/asdf` 的嵌套依赖

ASDF 自身带有一组子模块(其自测套件使用),一并归档:

| 目录 | 上游 | 固定提交 |
| --- | --- | --- |
| `home/asdf/ext/alexandria` | https://gitlab.common-lisp.net/alexandria/alexandria.git | `3b849bc0116ea70f215ee6b2fbf354e862aaa9dd` |
| `home/asdf/ext/asdf-encodings` | https://gitlab.common-lisp.net/asdf/asdf-encodings.git | `40a8670bff1e321eb2d779179d125bcfb158115c` |
| `home/asdf/ext/cl-launch` | https://gitlab.common-lisp.net/xcvb/cl-launch.git | `bed79a89f75850d9d217175a95af7281ef1c4a1a` |
| `home/asdf/ext/cl-ppcre` | https://github.com/edicl/cl-ppcre | `1ca0cd9ca0d161acd49c463d6cb5fff897596e2f` |
| `home/asdf/ext/cl-scripting` | https://github.com/fare/cl-scripting.git | `60c357e648ba5146a0a53b96fb73a3cc6ad387bd` |
| `home/asdf/ext/closer-closer-mop` | https://github.com/froggey/closer-mop.git | `e37cff6c2c90ddc49a6cc74c14e1c24e5041a53d` |
| `home/asdf/ext/fare-mop` | https://gitlab.common-lisp.net/frideau/fare-mop.git | `538aa94590a0354f382eddd9238934763434af30` |
| `home/asdf/ext/fare-quasiquote` | https://gitlab.common-lisp.net/frideau/fare-quasiquote.git | `640d39a0451094071b3e093c97667b3947f43639` |
| `home/asdf/ext/fare-utils` | https://gitlab.common-lisp.net/frideau/fare-utils.git | `66e9c6f1499140bc00ccc22febf2aa528cbb5724` |
| `home/asdf/ext/inferior-shell` | https://gitlab.common-lisp.net/qitab/inferior-shell.git | `e1f6378d75cea9eed243a793efa90cec55e401cb` |
| `home/asdf/ext/lisp-invocation` | https://gitlab.common-lisp.net/qitab/lisp-invocation.git | `ebf543ca17422dfbb51609f5b6d35a98c5f07449` |
| `home/asdf/ext/named-readtables` | https://github.com/melisgl/named-readtables.git | `985b1626e4af6fb083255c1757d530c1d14e8dbf` |
| `home/asdf/ext/optima` | https://github.com/m2ym/optima.git | `373b245b928c1a5cce91a6cb5bfe5dd77eb36195` |
