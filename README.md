<div align="center">

# Lambda64

**An operating system written entirely in Common Lisp — kernel, drivers, compiler, and GUI.**

[![CI](https://github.com/tiwe0/LBuild/actions/workflows/ci.yml/badge.svg)](https://github.com/tiwe0/LBuild/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](#license)
[![Language: Common Lisp](https://img.shields.io/badge/language-Common%20Lisp-lightgrey.svg)](https://common-lisp.net/)
[![Target: AArch64](https://img.shields.io/badge/target-AArch64-success.svg)](#why-arm64)

**English** · [简体中文](README.zh-CN.md)

</div>

---

Lambda64 is a from-scratch operating system in which every layer — the
supervisor, the device drivers, the memory manager, the compiler, and the
window system — is Common Lisp. There is no C runtime underneath: 334 Lisp
source files and no `.c` file at all. The only non-Lisp component is the KBoot
shim that hands control to the image.

It is a continuation of [Mezzano](https://github.com/froggey/Mezzano), rebuilt
around **AArch64 as the primary target** and carried to a working graphical
desktop there.

Because the compiler runs inside the running system, Lambda64 can rewrite,
recompile, and reload any part of itself without rebooting — the property that
makes it our platform for an **AI-native operating system**. See
[Why Lisp](#why-lisp).

## Features

| | |
| --- | --- |
| **Kernel** | Pure Common Lisp supervisor: paging, scheduling, SMP, interrupts |
| **Memory** | Generational copying collector with young/old semispaces |
| **Compiler** | Self-hosting, SSA-based, with AArch64 and x86-64 backends |
| **Language** | Full Common Lisp: CLOS and the MOP, conditions and restarts, macros, reader, `format` |
| **Persistence** | Image snapshots — the entire live system is written to disk and resumes where it stopped |
| **Graphics** | Compositor, window management, font rendering, AArch64 SIMD blitter |
| **Network** | Ethernet, ARP, IP, TCP, UDP, DHCP, DNS, HTTP |
| **Filesystems** | ext4, FAT32, local, remote, HTTP |
| **Drivers** | virtio block / net / GPU / input, USB EHCI with HID keyboard and mouse, RTL8168 Ethernet, Intel GMA graphics, Intel HDA audio |
| **Live development** | SWANK — connect SLIME to the running system and edit it in place |

### Applications

A REPL (basic and fancy), the **med** editor, a file manager, an image viewer,
an IRC client, a telnet client, a Mandelbrot explorer, a memory monitor, a
system inspector (`peek`), an event spy, and a settings panel — all running on
the compositor. [McCLIM](https://github.com/froggey/McCLIM) is included for
building more.

## What Lambda64 adds over Mezzano

The headline is that **AArch64 went from not booting to a usable desktop**.
Beyond that, in eight areas:

<details open>
<summary><b>Boot and bring-up (AArch64)</b></summary>

- 21 root causes fixed across the cold generator, compiler, runtime, GC,
  supervisor, drivers, and network layers
- Hardened cold paging bootstrap: wait queues before interrupts, pager serviced
  during paging setup, scheduling enabled before paging discovery, store
  freelist ordered against the pager
- Correct EL1h exception return; threads held on `SP_EL0` / EL1t stack mode
- Generic timer deferred to time-subsystem init, driven by direct register
  writes, with early interrupts guarded
- Interrupt enable sequenced behind scheduler readiness
- 16 MB main thread stack with published functions pre-faulted

</details>

<details>
<summary><b>Compiler and backend</b></summary>

- SSA correctness: non-local-exit contours modelled in the CFG, critical-edge
  splitting enforced before SSA, dominator block numbering centralized
- NLX jump tables emitted as trailers on both AArch64 and x86
- AArch64: 128-bit DCAS lowering, pointer CAS, literal-pool load width decoding,
  encodable immediate offsets, wrapping logical masks, large argument-count
  checks, GC-safe register swaps, reserved GC scratch registers, SIMD spill
  alignment, `tbz`/`tbnz` disassembly
- x86: compacted stack layout, `push imm8` short form, reverse scalar SSE moves,
  byte predicate temporaries, float equality
- Representation analysis: `ub64` over-promotion fixed, disjoint integer type
  intersections preserved, exact scalar complex short-floats promoted, boxed
  single floats built in place
- Debug values preserved across call canonicalization; unreachable calls
  terminated rather than emitted

</details>

<details>
<summary><b>Cold generator and image serialization</b></summary>

- Fixed the loss of every `(SETF ...)` definition caused by a weak-key table
  holding freshly consed list names
- Deterministic root traversal; object initialization through a work queue
- Structure slot initfunctions, class metadata, and source locations preserved
- Wide characters in cold strings, array rank validation, unboxed slot bit
  packing, immediate byte bounds checking
- Interrupt handlers direct-called through function references

</details>

<details>
<summary><b>Runtime, GC, and allocator</b></summary>

- Thread-local allocation buffers moved from per-CPU to per-thread; allocation
  counters from global atomics to per-CPU fields
- Function-reference publication fenced and synchronized; funcallable-instance
  entry points synchronized
- Allocation in restricted contexts unified behind one `with-allocator-lock`
  macro across all seven acquisition sites, with a world-stopper check
- GC finalizer errors isolated; weak-pointer-pair class hash with dead-key
  pruning
- Freelist card table updates linearized
- Superseded instance layouts published atomically

</details>

<details>
<summary><b>CLOS and the language core</b></summary>

- Repaired `restart-case`, which had been expanding to literal `NIL`
- `make-instance` initargs validated through the protocol; method combination
  lookup dispatched on the standard generic-function prototype
- Effective-method cache paths fixed, `defgeneric` declarations accumulated,
  struct parent subclass links maintained, structure layout class hashes
  initialized
- `loop` macro environment initialization, readtable dispatch accessor locking,
  explicit `format` package shadowing

</details>

<details>
<summary><b>Supervisor and drivers</b></summary>

- virtio MMIO devices claimed through a driver registry instead of a built-in
  dispatch table; GIC interrupts routed by type; typed IRQ FIFOs
- AArch64 cache and DMA maintenance ranges aligned; architecture-aware DMA flush
- USB/EHCI: qTD dequeue and reclamation, periodic table init, buffer allocation,
  port debounce, rewritten HID keyboard and mouse drivers
- Pager writable capability enforced; writes to unmapped blocks guarded
- Disks and snapshots synchronized before reboot; Intel GMA modeset timing
  hardened; Intel HDA reset polling bounded

</details>

<details>
<summary><b>Testing</b></summary>

- 252 host contract tests that run without building an image
- A real AArch64 `SCAVENGE-OBJECT` code-generation regression
- Integration and stress matrices with injected failures and SMP / single-CPU /
  low-memory variants, each managing its own file server
- Build provenance manifests recording image SHA-256, revision, subtree hash,
  dirty-tree flag, build command, and tool versions

</details>

<details>
<summary><b>Build and project structure</b></summary>

- The OS and its build system share one commit graph, so cross-layer changes
  and their tests are reviewed and released together
- The `home/` libraries are tracked in-tree rather than as submodules, so
  upstream changes cannot alter what this tree builds
  ([details](docs/reference/vendored-libraries.md))
- AArch64 as the default target with graphical QEMU launch targets
- 472 documentation files under an automated validator

</details>

## Getting started

### Prerequisites

| | |
| --- | --- |
| SBCL | 64-bit, with Unicode (2.6.8 verified) |
| QEMU | with `qemu-system-aarch64` (10.2.1 verified) |
| Make | GNU Make |
| Quicklisp | for the host-side build libraries |

```common-lisp
(ql:quickload '(alexandria iterate nibbles cl-fad cl-ppcre closer-mop trivial-gray-streams))
```

### Build

```sh
git clone https://github.com/tiwe0/LBuild.git
cd LBuild
make asdf          # build ASDF from the in-tree source
make cold-image    # cross-compile lambda64.image
```

The result is `lambda64.image`: a 5 GiB sparse store that occupies about 590 MB
on disk.

### Run

Start the host file server in one terminal — the guest compiles against it:

```sh
make run-file-server
```

And boot in another:

| Command | Accelerator | Platform |
| --- | --- | --- |
| `make hvf-arm64` | HVF | Apple Silicon |
| `make kvm-arm64` | KVM | Linux |
| `make qemu-arm64` | TCG | anywhere |

Adjust with `MEMORY`, `CPUS`, `RESOLUTION`, and `FILE_SERVER_IP`:

```sh
make hvf-arm64 MEMORY=8G CPUS=8 RESOLUTION=1920x1080
```

**The first boot takes about twenty minutes** and the screen stays black until
the graphics transport is claimed near the end. Compiled `.llf` files are
written back to `home/`, so later boots reach the desktop in a few minutes.

### Live development

Once the system reaches SWANK it accepts a connection on the forwarded port, and
any error after that point parks the failing thread rather than halting the
machine, so it can be inspected in place:

```
M-x slime-connect RET 127.0.0.1 RET 4005
```

### The boot pipeline

```
SBCL (host)                      cross-compiles Lambda64 sources
    │
    ├─ cold generator ─────────▶ lambda64.image
    │
QEMU -kernel KBoot               loads the image from virtio-blk
    │
    ├─ supervisor bootstrap      paging, pager, GIC, timer, scheduler, SMP
    ├─ cold start                runtime, packages, CLOS
    ├─ warm modules              precompiled .llf loaded from the image
    ├─ stage four                remaining systems compiled from source over
    │                            TCP 2599 from the host file server;
    │                            results written back to home/ as .llf
    ├─ IPL                       graphics and input claimed, GUI loaded,
    │                            compositor and desktop started
    └─ snapshot                  the live system is written back to disk
```

Stage four is what makes the first boot long and every later boot short. The
snapshot at the end is why the system resumes where it stopped rather than
starting cold again.

### Verified environment

| | |
| --- | --- |
| Host | macOS 27.0, Apple Silicon |
| SBCL / QEMU | 2.6.8 / 10.2.1 |
| Accelerator | HVF (`-machine virt -cpu host`); TCG exercised by the test suite |
| Guest | 4 GB RAM, 4 CPUs, 1280×800 |

`highmem` must stay enabled and memory must be at least 4 GB: stage four needs
address space above the 4 GB line, and below it the guest reports
`Addressing limited to 32 bits`.

KVM on Linux and the inherited x86-64 target are not part of this verification.

## Why Lisp

A Lisp system is self-describing and self-modifying by construction. The
compiler is part of the running image, code is data, and any function, class, or
method can be redefined while the system runs. In Lambda64 this reaches all the
way down: the scheduler and the device drivers are ordinary Lisp objects that
can be recompiled from a REPL attached to the live machine.

That property is the point. An operating system that can safely rewrite its own
components at runtime is the natural substrate for one that **evolves itself**,
with a model in the loop proposing, compiling, and validating changes against a
system that never has to stop. Building an **AI-native operating system** on
that foundation is the project's next objective.

To be clear about status: that work has not started. The features listed above
are what exists today.

## Why ARM64

**A simpler instruction set.** AArch64 is fixed-width and regular, with none of
x86's variable-length encoding, prefix soup, or legacy modes. For a compiler
backend that must be written, debugged, and reasoned about in Lisp, that is a
direct reduction in the amount of machine complexity the system has to model.

**Wider hardware reach.** ARM64 spans phones, tablets, single-board computers,
laptops, and servers. An OS that targets it first can follow the hardware where
it actually is, rather than being confined to the desktop.

## Contributing

Contributions are welcome. Before opening a pull request:

```sh
make test-fast                 # host contract tests + codegen regression
python3 scripts/check-docs.py  # documentation validation
```

Guidelines:

- **Test behaviour, not text.** Contract tests here assert semantics and are
  checked by mutation — a test that passes against deliberately broken code is
  a bug in the test.
- **Respect allocation contexts.** Code running with the world stopped, with
  interrupts masked, or holding the allocator lock may not allocate. See
  [allocation-forbidden contexts](docs/development/allocation-forbidden-contexts.md).
- **Follow the house style.** See [Common Lisp style](docs/development/common-lisp-style.md).
- **Explain why in commit messages.** What changed is visible in the diff; why
  it changed is not.

Larger changes are tracked in the
[modernization roadmap](docs/modernization/roadmap.md) and the
[debt register](docs/modernization/debt-register.md). Engineering documentation
starts at [`docs/README.md`](docs/README.md).

## Acknowledgements

Lambda64 exists because of two projects:

- **[Mezzano](https://github.com/froggey/Mezzano)** by Sylvia Harrington and
  contributors — the operating system this work continues. The architecture,
  the compiler, the object model, and the graphics stack are theirs.
- **[MBuild](https://github.com/froggey/MBuild)** — the build system this
  repository is forked from.

Thanks also to the maintainers of the Common Lisp libraries vendored under
`home/`, listed with their origins in
[vendored-libraries.md](docs/reference/vendored-libraries.md).

Inherited package and variable names may still read `mezzano`. Those are
compatibility identifiers.

## License

MIT. See [`Lambda64/COPYING`](Lambda64/COPYING) for the full text and the list
of copyright holders.
