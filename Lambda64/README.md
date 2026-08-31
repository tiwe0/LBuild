# Lambda64

Lambda64 is an operating system written in Common Lisp, forked from
[froggey/Mezzano](https://github.com/froggey/Mezzano) and developed specifically
for ARM64 (AArch64).

![Lambda64 desktop](doc/screenshot1.png)

## Project scope

Lambda64 is the ARM64-focused operating system maintained in this repository.
Its primary development platform is QEMU's ARM `virt` machine, including a
graphical VirtIO GPU, keyboard, and mouse.

Mezzano is the historical upstream project. Some internal Common Lisp package names, boot
protocol names, disk-format identifiers, and inherited output filenames still use
the legacy `mezzano` name for compatibility; they are implementation details,
not the Lambda64 project name.

## Building from source

Lambda64 uses [LBuild](https://github.com/tiwe0/LBuild) to generate its ARM64
cold image. LBuild is the Lambda64 build tool and includes this repository as
its `Lambda64/` submodule.

LBuild emits `lambda64.image`. The QEMU launcher also recognizes the legacy
`mezzano.image` filename for images produced by the historical upstream build
chain.

For day-to-day development, keep `Lambda64/` and `LBuild/` as sibling working
trees and copy `LBuild/local.mk.example` to `LBuild/local.mk`. LBuild will then
build the active sibling Lambda64 checkout. The pinned submodule remains the
source of truth for reproducible CI and release builds.

## ARM64 development with QEMU

With an ARM64 image in the repository root or `build-arm64/`, start Lambda64 in
graphical mode:

```sh
./tools/run-qemu-arm64
```

The launcher uses QEMU's `virt` machine with VirtIO block, network, GPU,
keyboard, and mouse devices. It selects HVF automatically on Apple Silicon,
KVM when available on Linux, and otherwise falls back to TCG.

Use a different requested display size with:

```sh
./tools/run-qemu-arm64 --resolution 1280x800
```

For serial-only debugging or CI, keep the same virtual hardware while hiding
the host display window:

```sh
./tools/run-qemu-arm64 --headless
```

Run `./tools/run-qemu-arm64 --help` for image, CPU, accelerator, display, and
extra QEMU options.

## Upstream

- Operating-system upstream: [froggey/Mezzano](https://github.com/froggey/Mezzano)
- Lambda64 build system: [tiwe0/LBuild](https://github.com/tiwe0/LBuild)
- Historical build-system upstream: [froggey/MBuild](https://github.com/froggey/MBuild)
- Upstream releases: [Mezzano releases](https://github.com/froggey/Mezzano/releases)
- Upstream community: `#mezzano` on Libera Chat (`irc.libera.chat`)

Upstream images and release notes describe Mezzano and should not be presented
as Lambda64 ARM64 releases.

## Asset attribution

"Hypothymis azurea - Kaeng Krachan" by JJ Harrison
([CC BY-SA 3.0](http://creativecommons.org/licenses/by-sa/3.0)), via Wikimedia
Commons:
https://commons.wikimedia.org/wiki/File:Hypothymis_azurea_-_Kaeng_Krachan.jpg

"Mandarin Pair" by Francis C. Franklin, licensed under
[CC BY-SA 3.0](http://creativecommons.org/licenses/by-sa/3.0):
http://commons.wikimedia.org/wiki/File:Mandarin_Pair.jpg

"Handsome" by Andy Morffew:
https://www.flickr.com/photos/andymorffew/19377769093/in/album-72157630893775092/
([CC BY 2.0](http://creativecommons.org/licenses/by/2.0))

Includes [DejaVu Fonts 2.37](https://dejavu-fonts.github.io/). Some icons are
from [Icojam](http://www.icojam.com).
