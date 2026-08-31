# Lambda64 local test system

The primary test surface is local. GitHub Actions consumes the same scripts,
manifest format, serial protocol, and QEMU oracle; it is not a separate test
implementation.

## Test pyramid

| Layer | What it proves | Local entry |
|---|---|---|
| Build-script unit | Temporary config restoration, artifact validation, strict provenance manifest, and matrix construction | `make -C ../LBuild test-scripts` |
| Host contracts | Shell protocol behavior, failure races, dirty-image policy, ARM64 register policy, and exact guest catalog | `tests/host/run.sh` |
| ARM64 code generation | The real cross-compiler preserves `SCAVENGE-OBJECT`'s cycle kind and does not recreate the X13/X14 CFG spill corruption | `tools/ci/test-arm64-scavenge-codegen.sh` |
| Guest runtime | Integer/bignum arithmetic, arrays, strings, sequences, hash tables, closures, multiple values, conditions, packages, structures, CLOS, and weak pointers | Run inside the test image |
| Guest GC and allocation | Repeated major GC, deterministic minor-to-major transition, old-to-young write barrier, post-major TLAB allocation, pinned objects, verifier restoration, and SMP allocation | Run inside the test image |
| Boot integration | Cold load, warm load, file-server access, complete 26-test guest catalog, semihosting exit, and immutable base image | `make -C ../LBuild test-integration` |
| Fault injection | The sentinel produces exactly one intentional failure, no false success milestone, and the expected nonzero guest exit | Included in `test-integration` |
| Stress | Repeated SMP boots, single CPU, constrained memory, and injected failure against one immutable image | `make -C ../LBuild test-stress` |

## Canonical local commands

From the sibling `LBuild` checkout:

```sh
make test-unit          # shell/build contracts; seconds
make test-codegen       # real ARM64 cross-compiler regression
make test-fast          # unit + code generation
make test-integration   # build once, positive and injected QEMU boots
make test-stress        # repeated/resource matrix against one image
make test-all           # complete local system: integration + stress
```

`test-integration` and `test-stress` write an isolated directory under
`LBuild/test-results/`. Each scenario retains:

- the complete serial log;
- smoke-runner console output;
- manifest SHAs, dirty flags, CPU/memory configuration, timeout state, QEMU
  exit, oracle exit, and before/after image hashes;
- a matrix-wide `summary.tsv` and `report.md`;
- the file-server log.

Local development may test an honestly marked dirty image with the explicit
smoke-runner `--allow-dirty` flag. The flag is recorded in evidence. Clean
automation remains fail-closed because it never passes this option.

## Guest protocol and acceptance rules

The guest catalog is explicit and fail-closed. `runner.lisp` rejects missing,
unexpected, or duplicate test names before executing any test. A positive run
is accepted only when all 26 catalogued tests emit one PASS record each, no
FAIL records exist, exactly one canonical summary reports `pass=26 fail=0`,
the success milestone appears, and QEMU returns the positive semihosting exit.

An injected run is accepted only when the sentinel produces exactly:

```text
LAMBDA64_TEST_FAIL harness.injected intentional
LAMBDA64_TEST_SUMMARY pass=0 fail=1
```

The oracle rejects panics, allocation during GC, debugger entry, unhandled
conditions, timeouts, exit/status disagreement, partial test discovery, and
base-image modification. Every QEMU boot uses `-snapshot`.

## Scope boundaries

The current deterministic local system covers the portable ARM64 `virt`
machine and TCG. Device-specific physical hardware, KVM/HVF accelerator
differences, network interoperability beyond the boot file server, graphical
pixel output, and long-duration soak/fuzz testing require separate hardware or
specialized lanes. They must not be inferred from a green TCG result.
