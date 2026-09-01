# LBuild

This repository contains the Lambda64 operating-system source under
`Lambda64/` together with its ARM64 build and local-test environment. LBuild
is forked from
[froggey/MBuild](https://github.com/froggey/MBuild), which remains the upstream
build-system project.

Lambda64 is a normal first-party directory, not a submodule. Its original Git
history was merged without squashing. LBuild defaults to the ARM64 target,
emits `lambda64.image`, and provides graphical QEMU launch targets.

## Prerequisites

- A recent 64-bit SBCL build with Unicode support
- Quicklisp
- QEMU with `qemu-system-aarch64`
- GNU Make

Install the required Common Lisp systems with Quicklisp:

```common-lisp
(ql:quickload '(alexandria iterate nibbles cl-fad cl-ppcre closer-mop trivial-gray-streams))
```

## Repository layout

```text
LBuild/
├── Lambda64/
├── docs/
├── home/
├── scripts/
└── Makefile
```

`local.mk` remains available for machine-specific QEMU, network, or toolchain
overrides, but normal development does not require a second checkout.

The maintained engineering documentation starts at [`docs/README.md`](docs/README.md).
It covers architecture, subsystem boundaries, testing, operations, security,
and the staged modernization roadmap. Historical notes under `Lambda64/doc/`
remain useful background but are not automatically current contracts.

## Local testing (primary workflow)

The complete test system is local-first. GitHub Actions reuses the same image
manifest, guest protocol, smoke runner, and serial oracle.

```sh
make test-unit          # build-script and host contract tests
make test-codegen       # real ARM64 SCAVENGE-OBJECT compiler regression
make test-fast          # both fast layers
make test-integration   # build test image, then positive + injected boots
make test-stress        # repeated SMP, 1 CPU, low memory, injected failure
make test-all           # complete local suite
```

The integration and stress targets start and stop their own Lambda64 file
server, always boot QEMU TCG with `-snapshot`, and save reports under
`test-results/`. They refuse to take over an existing listener on TCP 2599.
Override long-running parameters explicitly when needed:

```sh
make test-stress STRESS_REPETITIONS=5 LOCAL_TEST_TIMEOUT_SECONDS=6000
make test-all TEST_RESULTS_ROOT=/path/to/test-results
```

During development, manifests truthfully record a dirty monorepo. The local
matrix explicitly opts into testing those images and records that decision in
its evidence. Clean automation does not use that opt-in.

## Build and run quick start

Initialize LBuild's library submodules and build ASDF:

```sh
make deps
make asdf
```

Build the Lambda64 ARM64 cold image:

```sh
make cold-image
```

Build the CI test profile and its provenance manifest:

```sh
make test-image
```

`test-image` forces `CI=true`, requires the image, map, and symbol table to be
present and non-empty, and writes `lambda64.test-manifest`. The manifest records
the image SHA-256, exact repository revision, Lambda64 subtree hash, dirty
worktree flag, build command, and SBCL/QEMU versions. Consumers must reject
malformed manifests and production CI must reject a dirty tree.

Run only the build-script regression tests without building an image:

```sh
make test-scripts
```

The default QEMU user network reaches the host file server at `10.0.2.2`.
Override it for a different network:

```sh
make FILE_SERVER_IP=192.168.1.10 cold-image
```

Start the file server in a second terminal:

```sh
make run-file-server
```

> **Security:** the current legacy file server binds all interfaces and parses
> unauthenticated input with the Common Lisp reader. Run it only on a trusted,
> isolated host until the documented Gate 0 hardening is complete. See
> [`docs/security/host-file-server.md`](docs/security/host-file-server.md).

Run Lambda64 with graphical VirtIO GPU, keyboard, and mouse devices:

```sh
make qemu-arm64       # Portable TCG
make kvm-arm64        # Linux with KVM
make hvf-arm64        # Apple Silicon with HVF
```

The first boot performs warm initialization inside Lambda64 and compiles GUI
and library systems. The display may remain black during this stage. Generated
`.llf` files and the image snapshot make later boots substantially faster.

## Reproducible builds and releases

The repository contains all first-party source needed for a build. Clone its
remaining third-party library submodules and build from the repository root:

```sh
git clone --recurse-submodules https://github.com/tiwe0/LBuild.git
cd LBuild
make asdf cold-image
```

Lambda64 and build-system changes now share one commit graph, so cross-layer
changes and their tests can be reviewed and released atomically.

## Relationship to upstream

LBuild is the Lambda64 build tool. MBuild is its upstream and is referenced for
history and attribution, not as the project-facing build command.

Inherited Common Lisp packages and configuration variables may still contain
the name `mezzano`; those are compatibility identifiers, not current branding.
