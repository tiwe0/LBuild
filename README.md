<div align="center">

# LBuild

**A Lisp operating system that cold-boots to a live desktop on ARM64.**

[![CI](https://github.com/tiwe0/LBuild/actions/workflows/ci.yml/badge.svg)](https://github.com/tiwe0/LBuild/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](Lambda64/COPYING)
[![Language: Common Lisp](https://img.shields.io/badge/language-Common%20Lisp-lightgrey.svg)](https://common-lisp.net/)
[![Target: AArch64](https://img.shields.io/badge/target-AArch64-success.svg)](docs/architecture/arm64-boot-bring-up.md)

**English** · [简体中文](README.zh-CN.md)

</div>

---

LBuild builds **Lambda64**, an operating system written in Common Lisp — kernel,
drivers, compiler, GUI, and all. The host toolchain cross-compiles a cold image
from SBCL; the guest then finishes compiling itself from source and comes up as
a graphical desktop.

The OS source lives under `Lambda64/` as a normal first-party directory, not a
submodule, with its original Git history merged unsquashed. LBuild is forked
from [froggey/MBuild](https://github.com/froggey/MBuild), which remains the
upstream build-system project.

## At a glance

| | |
| --- | --- |
| **Target** | ARM64 / AArch64, on QEMU `virt` |
| **Host toolchain** | SBCL with Unicode + Quicklisp |
| **Output** | `lambda64.image` — a 5 GiB sparse store, ≈590 MiB on disk |
| **Boot chain** | cold load → warm modules → stage-4 compile over TCP 2599 → desktop |
| **Live devices** | virtio GPU framebuffer (1280×800), keyboard, mouse |

## Status

**ARM64 boots end to end.** Cold load, warm modules, stage-four dependency
compilation over the host file server, GUI, desktop, and the closing snapshot
all complete. The framebuffer, keyboard, and mouse are live.

Getting there took **21 root-cause fixes** spanning the cold generator, the
compiler, the runtime and GC, the supervisor and drivers, and the network and
file-system layers. Each is recorded with its symptom, its cause, and *why it
was hard to find* in
**[`docs/architecture/arm64-boot-bring-up.md`](docs/architecture/arm64-boot-bring-up.md)**.
That document's closing section — the three patterns that produced most of the
defects — is the part worth reading before changing this tree.

Known limitations live in the
[debt register](docs/modernization/debt-register.md). The visible one is
**D024**: virtio-gpu transfers and flushes the whole clip region synchronously
once per frame, so a window appearing at 1280×800 repaints visibly rather than
instantly.

## Quick start

```sh
git clone https://github.com/tiwe0/LBuild.git
cd LBuild
```

Install the Common Lisp systems the build needs:

```common-lisp
(ql:quickload '(alexandria iterate nibbles cl-fad cl-ppcre closer-mop trivial-gray-streams))
```

Then build and boot:

```sh
make asdf           # build ASDF (libraries are already in-tree)
make cold-image     # cross-compile lambda64.image
make run-file-server   # in a second terminal — the guest compiles against this
make hvf-arm64      # Apple Silicon (use qemu-arm64 for portable TCG, kvm-arm64 on Linux)
```

> [!IMPORTANT]
> **The first boot is long and the screen stays black for most of it.** The guest
> compiles the GUI and library systems from source over the file server;
> `ext4.lisp` alone takes about twenty minutes (see D021), and the display only
> lights up once the GPU transport is claimed late in IPL. Generated `.llf`
> files are written back to `home/`, so later boots reuse them and reach the
> desktop in a few minutes.
>
> Follow the serial log, not the window. A boot that *looks* stuck usually is
> not — check that QEMU is consuming CPU and that the log is still growing
> before concluding otherwise. Both signals, and how to read a guest panic when
> it really has stopped, are in
> [reading-arm64-panics.md](docs/development/reading-arm64-panics.md).

> [!WARNING]
> **Security.** The legacy host file server binds all interfaces and parses
> unauthenticated input with the Common Lisp reader. Run it only on a trusted,
> isolated host until the documented Gate 0 hardening lands. See
> [`docs/security/host-file-server.md`](docs/security/host-file-server.md).

## Running

| Target | Accelerator | Use on |
| --- | --- | --- |
| `make qemu-arm64` | TCG | anywhere (slow) |
| `make kvm-arm64` | KVM | Linux |
| `make hvf-arm64` | HVF | Apple Silicon |

All three attach virtio GPU, keyboard, and mouse. Override the guest's view of
the host file server when user networking's `10.0.2.2` is wrong:

```sh
make FILE_SERVER_IP=192.168.1.10 cold-image
```

### Live debugging

Once IPL reaches SWANK the guest accepts a connection on the forwarded port, and
an error after that point **parks the failing thread instead of halting the
machine** — so the failure can be inspected in place rather than reproduced:

```
M-x slime-connect RET 127.0.0.1 RET 4005
```

## Tested configuration

Everything below was developed and verified on **one host**. The other
accelerator targets are plausible, not proven — say so before relying on them.

| | Verified value |
| --- | --- |
| Host OS | macOS 27.0 (Darwin), Apple Silicon |
| SBCL | 2.6.8 |
| QEMU | 10.2.1 |
| Accelerator | `hvf` — `-machine virt -accel hvf -cpu host` |
| Memory | `MEMORY=4G` |
| CPUs | `CPUS=4` |
| Resolution | `RESOLUTION=1280x800` |

The exact device line behind the verified boots:

```text
-machine virt -accel hvf -cpu host
-m 4G -smp 4 -kernel Lambda64/tools/kboot/kboot-generic-arm64.bin
-serial stdio -monitor none -no-reboot
-device virtio-gpu-device,xres=1280,yres=800
-device virtio-keyboard-device
-device virtio-mouse-device
-drive if=none,file=lambda64.image,id=blk,format=raw
-device virtio-blk-device,drive=blk
-netdev user,id=vmnic,hostname=lambda64,hostfwd=tcp:127.0.0.1:4005-:4005
-device virtio-net-device,netdev=vmnic
-semihosting-config enable=on,target=native
```

Two of those are load-bearing and easy to "optimize" into a broken boot:

- **`highmem` stays on.** `highmem=off` caps guest RAM below the 4 GB line
  (`Addressing limited to 32 bits`). Stage-four dependency loading needs more
  than that, or function pages get evicted — and a no-IRQ region that touches an
  evicted page dies with `page-fault-no-irqs`.
- **`MEMORY=4G` is a floor, not a preference.** The same stage-four load is what
  forced it up from the previous default.

Also exercised on this host: the **TCG** path, which every `test-integration`
and `test-stress` run boots with `-snapshot`.

**Not exercised anywhere:** `make kvm-arm64`, which needs a Linux host, and the
x86-64 sources inherited from upstream, which this tree does not build.

## Testing

The test system is local-first; GitHub Actions reuses the same image manifest,
guest protocol, smoke runner, and serial oracle.

| Target | What it covers |
| --- | --- |
| `make test-unit` | build-script and host contract tests |
| `make test-codegen` | real ARM64 `SCAVENGE-OBJECT` compiler regression |
| `make test-fast` | both fast layers |
| `make test-integration` | builds a test image, then positive + injected boots |
| `make test-stress` | repeated SMP, 1 CPU, low memory, injected failure |
| `make test-all` | the complete local suite |

Integration and stress targets start and stop their own file server, always boot
QEMU TCG with `-snapshot`, and save reports under `test-results/`. They refuse
to take over an existing listener on TCP 2599. Long-running parameters are
overridable:

```sh
make test-stress STRESS_REPETITIONS=5 LOCAL_TEST_TIMEOUT_SECONDS=6000
make test-all TEST_RESULTS_ROOT=/path/to/test-results
```

<details>
<summary><b>Build provenance and the test image</b></summary>

```sh
make test-image     # CI profile + provenance manifest
make test-scripts   # build-script regressions only, no image
```

`test-image` forces `CI=true`, requires the image, map, and symbol table to be
present and non-empty, and writes `lambda64.test-manifest`. The manifest records
the image SHA-256, exact repository revision, Lambda64 subtree hash, dirty
worktree flag, build command, and SBCL/QEMU versions. Consumers must reject
malformed manifests, and production CI must reject a dirty tree.

During development, manifests truthfully record a dirty monorepo. The local
matrix explicitly opts into testing those images and records that decision in
its evidence; clean automation does not use that opt-in.

</details>

## Improvements over the original baseline

502 commits since the fork. This is the delta from the original baseline, so it
includes upstream work merged along the way as well as LBuild's own — the
headline is that **ARM64 went from not booting to reaching a usable desktop**.

<details open>
<summary><b>Boot and bring-up (ARM64)</b></summary>

- 21 root causes fixed, from the cold generator down to the drivers — each with
  symptom, cause, and why it was hard to find, in the
  [bring-up record](docs/architecture/arm64-boot-bring-up.md)
- Cold paging bootstrap hardened: wait queues initialized before IRQs, the pager
  serviced *during* paging setup, scheduling enabled before paging discovery,
  store freelist bootstrap ordered against the pager
- Correct EL1h exception return; threads kept on `SP_EL0` / EL1t stack mode
- ARM64 generic timer deferred until time init, driven by direct register
  writes, with early timer interrupts guarded
- Interrupt enable moved behind scheduler readiness
- Main thread stack raised to 16 MB, and published functions pre-faulted

</details>

<details>
<summary><b>Compiler and backend</b></summary>

- **SSA correctness:** NLX contour CFG modeling restored, critical-edge
  splitting enforced before SSA, dominator block numbering centralized
- NLX jump tables emitted as trailers on both ARM64 and x86
- **ARM64:** 128-bit memref DCAS lowering, pointer CAS, literal-pool load width
  decoding, encodable immediate offsets, wrapping logical masks, large
  argument-count checks, GC-safe register swaps, reserved GC scratch registers,
  SIMD spill alignment, `tbz`/`tbnz` disassembly
- **x86:** compacted stack layout, `push imm8` short form, reverse scalar SSE
  moves, byte predicate temporaries, float equality
- **Representation analysis:** overly eager `ub64` promotion fixed, disjoint
  integer type intersections preserved, exact scalar complex short-floats
  promoted, boxed single floats built directly in their destination
- Debug values preserved across call canonicalization; proven-unreachable calls
  terminated rather than emitted

</details>

<details>
<summary><b>Cold generator and image serialization</b></summary>

- Stopped discarding **every** `(SETF ...)` definition — a weak-key table keyed
  on function names, which are freshly consed lists for `(SETF foo)` and so were
  collected immediately
- Deterministic root traversal ordering; object initialization through a work
  queue
- Structure slot initfunctions, class metadata, and source locations preserved
- Wide characters in cold strings, array rank validation, unboxed slot bit
  packing, immediate byte bounds checking
- Interrupt handlers direct-called via FREFs

</details>

<details>
<summary><b>Runtime, GC, and allocator</b></summary>

- TLABs moved from per-CPU to per-thread; allocation counters moved from global
  atomics to per-CPU fields
- Function-reference publication fenced and synchronized; funcallable-instance
  entry points synchronized
- Allocation in restricted contexts collapsed into a single `with-allocator-lock`
  macro covering all seven acquisition sites, with a world-stopper check — the
  rule had previously been written out correctly in exactly one of them
- GC finalizer errors isolated; weak-pointer-pair fast class hash with dead-key
  pruning
- Freelist card table updates linearized
- Superseded instance layouts published atomically

</details>

<details>
<summary><b>CLOS and the language core</b></summary>

- `restart-case` expansion repaired — it had been expanding to literal `NIL` for
  every use
- `make-instance` initargs validated through the protocol; method combination
  lookup dispatched on the standard generic-function prototype
- EMF cache paths fixed, `DEFGENERIC` declarations accumulated, struct parent
  subclass links maintained, structure layout class hashes initialized
- `loop` macro environment initialization, readtable dispatch accessor locking,
  explicit `format` package shadowing

</details>

<details>
<summary><b>Supervisor and drivers</b></summary>

- virtio MMIO devices claimed by their drivers through a registry instead of a
  built-in `case`; GIC interrupts routed by type; typed IRQ FIFOs
- ARM64 cache and DMA maintenance ranges aligned; architecture-aware DMA flush
- USB/EHCI: qTD dequeue and reclamation, periodic table init, buffer allocation,
  port debounce, and rewritten HID keyboard and mouse drivers
- Pager writable capability enforced; writes to unmapped blocks guarded
- Disks and snapshots synchronized before reboot; Intel GMA modeset timing
  hardened; Intel HDA controller reset polling bounded

</details>

<details>
<summary><b>Testing</b></summary>

- **252 host contract tests**, run without an image
- A real ARM64 `SCAVENGE-OBJECT` codegen regression
- Integration and stress matrices with injected failures and SMP / 1-CPU /
  low-memory variants, each managing its own file server and booting TCG with
  `-snapshot`
- A provenance manifest recording image SHA-256, exact revision, Lambda64
  subtree hash, dirty-worktree flag, build command, and tool versions

</details>

<details>
<summary><b>Build system and documentation</b></summary>

- Lambda64 merged in as a first-party directory with unsquashed history, so
  cross-layer changes and their tests share one commit graph
- ARM64 as the default target, graphical QEMU launch targets, `local.mk`
  overrides, and no second checkout
- **471 documentation files** under a validator (`scripts/check-docs.py`),
  including the bring-up record, the panic-reading guide, the
  allocation-forbidden-contexts rules, the debt register, and the modernization
  roadmap

</details>

## Repository layout

```text
LBuild/
├── Lambda64/    the operating system — supervisor, runtime, compiler, GUI
├── docs/        maintained engineering documentation
├── home/        guest-visible sources; compiled .llf files land back here
├── scripts/     build and test tooling
└── Makefile
```

`local.mk` is available for machine-specific QEMU, network, or toolchain
overrides, but normal development does not need a second checkout.

## Documentation

Start at **[`docs/README.md`](docs/README.md)** — architecture, subsystem
boundaries, testing, operations, security, and the staged modernization roadmap.

| Read this | When |
| --- | --- |
| [ARM64 bring-up record](docs/architecture/arm64-boot-bring-up.md) | before changing boot, allocation, or codegen |
| [Reading ARM64 panics](docs/development/reading-arm64-panics.md) | a guest panic or a boot that stopped |
| [Allocation-forbidden contexts](docs/development/allocation-forbidden-contexts.md) | touching the supervisor or the allocator |
| [Debt register](docs/modernization/debt-register.md) | picking up known-open work |

Historical notes under `Lambda64/doc/` remain useful background but are not
current contracts.

## Reproducible builds

A plain `git clone` is a complete build input. There are no submodules: the
`home/` libraries are tracked directly, so an upstream force-push or a silently
advanced pointer cannot change what this tree builds. Where each library came
from and the commit it was frozen at are recorded in
[vendored-libraries.md](docs/reference/vendored-libraries.md), along with the one
local patch that is not a pure mirror.

Lambda64 and the build system share one commit graph, so cross-layer changes and
their tests are reviewed and released atomically.

## Upstream and naming

LBuild is the Lambda64 build tool. MBuild is its upstream, referenced for
history and attribution rather than as the project-facing build command.

Inherited Common Lisp packages and configuration variables may still contain the
name `mezzano`. Those are compatibility identifiers, not current branding.

## License

MIT. See [`Lambda64/COPYING`](Lambda64/COPYING) for the full text and the list
of copyright holders.
