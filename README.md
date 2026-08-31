# LBuild

LBuild is the ARM64 build environment for
[Lambda64](https://github.com/tiwe0/Lambda64). It is forked from
[froggey/MBuild](https://github.com/froggey/MBuild), which remains the upstream
build-system project.

Lambda64 is pinned as the `Lambda64/` submodule for reproducible CI and release
builds. LBuild defaults to the ARM64 target, emits `lambda64.image`, and
provides graphical QEMU launch targets.

## Prerequisites

- A recent 64-bit SBCL build with Unicode support
- Quicklisp
- QEMU with `qemu-system-aarch64`
- GNU Make

Install the required Common Lisp systems with Quicklisp:

```common-lisp
(ql:quickload '(alexandria iterate nibbles cl-fad cl-ppcre closer-mop trivial-gray-streams))
```

## Recommended local layout

Keep the two repositories as sibling working trees. This lets each repository
stay on its own `arm64` branch without editing a detached submodule checkout:

```text
Project/
├── Lambda64/
└── LBuild/
```

Configure the local path once. `local.mk` is ignored by Git:

```sh
cd LBuild
cp local.mk.example local.mk
```

The example sets `LAMBDA64_DIR := ../Lambda64`. All LBuild commands then use
the sibling Lambda64 working tree while dependencies remain under
`LBuild/home/`.

## Quick start

Initialize LBuild's library submodules and build ASDF:

```sh
make deps
make asdf
```

Build the Lambda64 ARM64 cold image:

```sh
make cold-image
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

Without `local.mk`, LBuild uses its pinned `Lambda64/` submodule. This is the
recommended mode for CI and release builds:

```sh
git clone --recurse-submodules https://github.com/tiwe0/LBuild.git
cd LBuild
make asdf cold-image
```

When publishing a new pair of revisions, first commit and push Lambda64. Then
update the LBuild gitlink to that exact Lambda64 commit and commit LBuild. This
keeps release builds reproducible while local development remains convenient.

## Relationship to upstream

LBuild is the Lambda64 build tool. MBuild is its upstream and is referenced for
history and attribution, not as the project-facing build command.

Inherited Common Lisp packages and configuration variables may still contain
the name `mezzano`; those are compatibility identifiers, not current branding.
