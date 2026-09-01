#!/usr/bin/env bash
# Canonical contracts for runtime numeric fallback paths.
set -euo pipefail
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/../.." && pwd)
float_source=${RUNTIME_FLOAT_SOURCE:-"$repo_root/runtime/float-x86-64.lisp"}
numbers_source=${RUNTIME_NUMBERS_SOURCE:-"$repo_root/runtime/numbers.lisp"}
arm_source=${RUNTIME_ARM64_SOURCE:-"$repo_root/runtime/runtime-arm64.lisp"}
x86_source=${RUNTIME_X86_SOURCE:-"$repo_root/runtime/runtime-x86-64.lisp"}
mutation=${RUNTIME_NUMERIC_MUTATION_RUN:-}

python3 - "$float_source" "$numbers_source" "$arm_source" "$x86_source" "$mutation" <<'PY'
from pathlib import Path
import struct, sys

float_s, numbers_s, arm_s, x86_s, mutation = [Path(p).read_text(encoding="utf-8") if i < 4 else p
                                               for i, p in enumerate(sys.argv[1:])]
for label, source in (("float-x86-64", float_s), ("numbers", numbers_s),
                      ("runtime-arm64", arm_s), ("runtime-x86-64", x86_s)):
    if "TODO" in source or "FIXME" in source:
        raise SystemExit(f"runtime numeric marker remains: {label}")

if mutation:
    # Mutation probe: deleting the documented fallback rationale must be
    # detected, rather than allowing a source-only test to pass accidentally.
    numbers_s = numbers_s.replace("integer canonicalization in one place.", "", 1)
if "integer canonicalization in one place." not in numbers_s:
    raise SystemExit("runtime.numeric.truncate fallback rationale missing")
if "canonical slow path" not in arm_s or "canonical slow path" not in x86_s:
    raise SystemExit("runtime.numeric.shift fallback rationale missing")

# runtime.numeric.truncate: model the IEEE decode used by %%truncate-*.
def decode(bits, frac_bits, exp_bits, bias, sign_bit):
    sig = (bits & ((1 << frac_bits) - 1)) | (1 << frac_bits)
    exponent = ((bits >> frac_bits) & ((1 << exp_bits) - 1)) - bias
    value = sig << (exponent - frac_bits) if exponent >= frac_bits else sig >> (frac_bits - exponent)
    return -value if (bits >> sign_bit) else value
for value in (0.0, 1.0, -1.0, 3.75, 2**20 + 0.5):
    bits = struct.unpack('<Q', struct.pack('<d', value))[0]
    expected = int(value)
    if decode(bits, 52, 11, 1023, 63) != expected:
        raise SystemExit(f"runtime.numeric.truncate failed for {value}")

# runtime.numeric.shift: slow fallback is mathematically repeated doubling.
for integer, count in ((1, 0), (3, 5), (-3, 4), (7, 9)):
    result = integer
    for _ in range(count): result += result
    if result != integer * (1 << count):
        raise SystemExit("runtime.numeric.shift model failed")

print("runtime.numeric.truncate contract passed")
print("runtime.numeric.shift contract passed")
PY

if [[ -z "$mutation" ]]; then
  if RUNTIME_NUMERIC_MUTATION_RUN=1 bash "$0" >/dev/null 2>&1; then
    echo "runtime numeric mutation unexpectedly survived" >&2
    exit 1
  fi
  echo "runtime numeric mutation rejected"
fi
