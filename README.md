<div align="center">

# Lambda64

**An operating system implemented entirely in Common Lisp: kernel, drivers, compiler, and graphical environment.**

[![CI](https://github.com/tiwe0/LBuild/actions/workflows/ci.yml/badge.svg)](https://github.com/tiwe0/LBuild/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](#license)
[![Language: Common Lisp](https://img.shields.io/badge/language-Common%20Lisp-lightgrey.svg)](https://common-lisp.net/)
[![Target: AArch64](https://img.shields.io/badge/target-AArch64-success.svg)](#why-arm64)

**English** · [简体中文](README.zh-CN.md)

</div>

---

Lambda64 is an operating system implemented entirely in Common Lisp. The
supervisor, device drivers, memory manager, compiler, and window system are all
written in the language. The source tree contains 334 Lisp files and no C; the
only non-Lisp component is the KBoot shim, which transfers control to the image.

The project continues [Mezzano](https://github.com/froggey/Mezzano), with
AArch64 established as the primary target and brought to a functioning
graphical desktop on that architecture.

The compiler is part of the running image. Any component may therefore be
redefined, recompiled, and reloaded without restarting the system, which is the
basis for the project's stated direction. See [Why Lisp](#why-lisp).

## Features

| | |
| --- | --- |
| **Kernel** | Pure Common Lisp supervisor: paging, scheduling, SMP, interrupts |
| **Memory** | Generational copying collector with young/old semispaces |
| **Compiler** | Self-hosting and SSA-based, with AArch64 and x86-64 backends |
| **Language** | Complete Common Lisp: CLOS and the MOP, conditions and restarts, macros, reader, `format` |
| **Persistence** | Image snapshots: the complete running system is written to disk and resumed from that state |
| **Graphics** | Compositor, window management, font rendering, AArch64 SIMD blitter |
| **Network** | Ethernet, ARP, IP, TCP, UDP, DHCP, DNS, HTTP |
| **Filesystems** | ext4, FAT32, local, remote, HTTP |
| **Drivers** | virtio block / net / GPU / input, USB EHCI with HID keyboard and mouse, RTL8168 Ethernet, Intel GMA graphics, Intel HDA audio |
| **Live development** | SWANK, permitting SLIME to connect to and modify the running system |

### Applications

The distribution includes two REPLs, the `med` editor, a file manager, an image
viewer, an IRC client, a telnet client, a Mandelbrot viewer, a memory monitor, a
system inspector (`peek`), an event tracer, and a settings panel, all hosted by
the compositor. [McCLIM](https://github.com/froggey/McCLIM) is provided for
developing additional applications.

## What Lambda64 adds over Mezzano

The principal result is that AArch64 progressed from a non-booting state to a
functioning desktop environment. The complete set of changes falls into eight
areas.

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

## Installation and use

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

The build produces `lambda64.image`, a sparse store with a nominal capacity of
5 GiB that occupies approximately 590 MB on disk.

### Run

The guest compiles its remaining systems against a host file server, which must
be running before the guest is started:

```sh
make run-file-server
```

The system is then booted with one of the following targets:

| Command | Accelerator | Platform |
| --- | --- | --- |
| `make hvf-arm64` | HVF | Apple Silicon |
| `make kvm-arm64` | KVM | Linux |
| `make qemu-arm64` | TCG | anywhere |

Adjust with `MEMORY`, `CPUS`, `RESOLUTION`, and `FILE_SERVER_IP`:

```sh
make hvf-arm64 MEMORY=8G CPUS=8 RESOLUTION=1920x1080
```

The first boot requires approximately twenty minutes, during which the display
remains inactive until the graphics transport is claimed late in the
initialization sequence. Compiled `.llf` files are written back to `home/`;
subsequent boots reuse them and reach the desktop within a few minutes.

### Live development

Once initialization reaches SWANK, the system accepts a connection on the
forwarded port. Errors raised after that point suspend the failing thread rather
than halting the machine, allowing the failure to be examined in place:

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

Stage four accounts for the duration of the first boot and for the brevity of
subsequent ones. The concluding snapshot enables the system to resume from its
previous state rather than initializing from cold.

### Verified environment

| | |
| --- | --- |
| Host | macOS 27.0, Apple Silicon |
| SBCL / QEMU | 2.6.8 / 10.2.1 |
| Accelerator | HVF (`-machine virt -cpu host`); TCG exercised by the test suite |
| Guest | 4 GB RAM, 4 CPUs, 1280×800 |

`highmem` must remain enabled and guest memory must be at least 4 GB. Stage four
requires address space above the 4 GB boundary; below it, the guest reports
`Addressing limited to 32 bits`.

KVM on Linux and the inherited x86-64 target are outside the scope of this
verification.

## Why Lisp

A Lisp system is self-describing and self-modifying by construction. The
compiler forms part of the running image, program text is data, and functions,
classes, and methods may be redefined while the system executes. In Lambda64
this property extends to the lowest levels: the scheduler and the device drivers
are ordinary Lisp objects and can be recompiled from a REPL attached to the
running machine.

This is the project's principal rationale. An operating system capable of
safely rewriting its own components at runtime is a suitable substrate for a
self-evolving system, in which a model participates in proposing, compiling, and
validating modifications against an instance that need not be stopped.
Constructing an AI-native operating system on that foundation is the project's
next objective.

This work has not yet begun. The capabilities described above are those
presently implemented.

## Why ARM64

AArch64 uses a fixed-width, regular encoding and has none of the
variable-length instruction forms, prefix sequences, or legacy operating modes
of x86. For a compiler backend that must be implemented, debugged, and reasoned
about in Lisp, this represents a direct reduction in the machine complexity the
system is required to model.

AArch64 additionally spans a wider range of hardware, from mobile devices and
single-board computers to laptops and servers. Targeting it first allows the
system to follow current hardware deployment rather than remaining confined to
desktop platforms.

## Contributing

The following must pass before a pull request is submitted:

```sh
make test-fast                 # host contract tests + codegen regression
python3 scripts/check-docs.py  # documentation validation
```

Requirements for contributed changes:

- **Contract tests must assert semantics rather than source text.** Tests in
  this repository are verified by mutation: a test that continues to pass
  against deliberately broken code is itself defective.
- **Allocation constraints must be observed.** Code executing with the world
  stopped, with interrupts masked, or while holding the allocator lock must not
  allocate. Refer to
  [allocation-forbidden contexts](docs/development/allocation-forbidden-contexts.md).
- **Source must conform to the project style.** Refer to
  [Common Lisp style](docs/development/common-lisp-style.md).
- **Commit messages must state the rationale for a change.** The content of a
  change is evident from the diff; its justification is not.

Substantial changes are tracked in the
[modernization roadmap](docs/modernization/roadmap.md) and the
[debt register](docs/modernization/debt-register.md). Engineering documentation
begins at [`docs/README.md`](docs/README.md).

## Acknowledgements

This project derives from two others:

- **[Mezzano](https://github.com/froggey/Mezzano)**, by Sylvia Harrington and
  contributors, is the operating system that this work continues. Its
  architecture, compiler, object model, and graphics stack are the foundation
  of Lambda64.
- **[MBuild](https://github.com/froggey/MBuild)** is the build system from which
  this repository is forked.

Acknowledgement is also due to the maintainers of the Common Lisp libraries
distributed under `home/`, which are listed with their origins in
[vendored-libraries.md](docs/reference/vendored-libraries.md).

Inherited package and variable names may still contain the string `mezzano`.
These are compatibility identifiers and do not denote current naming.

## License

MIT. See [`Lambda64/COPYING`](Lambda64/COPYING) for the full text and the list
of copyright holders.
