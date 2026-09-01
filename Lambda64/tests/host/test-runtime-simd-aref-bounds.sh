#!/usr/bin/env bash
# Regression coverage for SIMD AREF's checked final-lane bounds.
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "$script_dir/../.." && pwd)
source_file=${SIMD_ARM64_SOURCE:-"$repo_root/runtime/simd-arm64.lisp"}

python3 - "$source_file" "${SIMD_AREF_BOUNDS_MUTATION_RUN:-}" <<'PY'
from pathlib import Path
import sys

source = Path(sys.argv[1]).read_text(encoding="utf-8")
marker = "(defmacro %define-aref-transforms"
start = source.index(marker)
end = source.index("\n\n;;; Generate aref accessors", start)
form = source[start:end]
if sys.argv[2]:
    form = form.replace("(funcall #',row-major-aref", "(funcall #',%row-major-aref", 1)
required = [
    "(defun ,aref",
    "(funcall #',row-major-aref",
    "(assert (<= (+ index ,(* n-lanes count)) (array-total-size array)))",
]
missing = [token for token in required if token not in form]
if missing:
    raise SystemExit("SIMD AREF bounds contract missing: " + ", ".join(missing))
print("SIMD AREF final-lane bounds contract passed")
PY

if [[ -z "${SIMD_AREF_BOUNDS_MUTATION_RUN:-}" ]]; then
  if SIMD_AREF_BOUNDS_MUTATION_RUN=1 bash "$0" >/dev/null 2>&1; then
    echo "SIMD AREF bounds mutation unexpectedly survived" >&2
    exit 1
  fi
  echo "SIMD AREF bounds mutation rejected"
fi
