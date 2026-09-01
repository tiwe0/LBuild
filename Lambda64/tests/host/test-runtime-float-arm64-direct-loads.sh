#!/usr/bin/env bash
# Regression coverage for direct ARM64 floating-point loads.
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "$script_dir/../.." && pwd)
source_file=${FLOAT_ARM64_SOURCE:-"$repo_root/runtime/float-arm64.lisp"}

python3 - "$source_file" "${FLOAT_DIRECT_LOADS_MUTATION_RUN:-}" <<'PY'
from pathlib import Path
import sys

source = Path(sys.argv[1]).read_text(encoding="utf-8")
if sys.argv[2]:
    source = source.replace(
        "(mezzano.lap.arm64:ldr :d0 (:object :x0 0))",
        "(mezzano.lap.arm64:ldr :x9 (:object :x0 0))",
        1,
    )
required = [
    "(mezzano.lap.arm64:ldr :d1 (:object :x1 0))",
    ";; Load double-float slots directly into FP registers.",
]
missing = [token for token in required if token not in source]
direct_d0 = "(mezzano.lap.arm64:ldr :d0 (:object :x0 0))"
if source.count(direct_d0) != 2:
    missing.append(f"{direct_d0} (expected twice, found {source.count(direct_d0)})")
if missing:
    raise SystemExit("ARM64 direct floating-load contract missing: " + ", ".join(missing))
if "FIXME: LDR should support loads directly into d0" in source:
    raise SystemExit("ARM64 direct floating-load FIXME remains")
print("ARM64 direct floating-load contract passed")
PY

if [[ -z "${FLOAT_DIRECT_LOADS_MUTATION_RUN:-}" ]]; then
  if FLOAT_DIRECT_LOADS_MUTATION_RUN=1 bash "$0" >/dev/null 2>&1; then
    echo "ARM64 direct floating-load mutation unexpectedly survived" >&2
    exit 1
  fi
  echo "ARM64 direct floating-load mutation rejected"
fi
