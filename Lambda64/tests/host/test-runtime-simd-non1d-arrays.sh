#!/usr/bin/env bash
# Regression coverage for SIMD AREF support of displaced and non-1D arrays.
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "$script_dir/../.." && pwd)
source_file=${SIMD_ARM64_SOURCE:-"$repo_root/runtime/simd-arm64.lisp"}

python3 - "$source_file" "${SIMD_NON1D_ARRAYS_MUTATION_RUN:-}" <<'PY'
from pathlib import Path
import sys

source = Path(sys.argv[1]).read_text(encoding="utf-8")
marker = "(defmacro %define-aref-transforms"
start = source.index(marker)
end = source.index("\n\n;;; Generate aref accessors", start)
form = source[start:end]
if sys.argv[2]:
    form = form.replace("(array ,scalar-type *)", "(simple-array ,scalar-type *)", 1)

required = [
    "(array ,scalar-type *)",
    "(array-displacement array)",
    "(int::%object-ref-t array ,int::+complex-array-storage+)",
    "(check-type storage (simple-array ,scalar-type *))",
    "(+ index offset)",
]
missing = [token for token in required if token not in form]
if "TODO: Support other non-1D arrays" in form:
    missing.append("TODO marker removal")
if missing:
    raise SystemExit("SIMD non-1D array contract missing: " + ", ".join(missing))
print("SIMD non-1D array contract passed")
PY

if [[ -z "${SIMD_NON1D_ARRAYS_MUTATION_RUN:-}" ]]; then
  if SIMD_NON1D_ARRAYS_MUTATION_RUN=1 bash "$0" >/dev/null 2>&1; then
    echo "SIMD non-1D array mutation unexpectedly survived" >&2
    exit 1
  fi
  echo "SIMD non-1D array mutation rejected"
fi
