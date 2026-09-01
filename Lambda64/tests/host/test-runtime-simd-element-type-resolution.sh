#!/usr/bin/env bash
# Regression coverage for SIMD integer element-type resolution.
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "$script_dir/../.." && pwd)
source_file=${SIMD_SOURCE:-"$repo_root/runtime/simd.lisp"}

python3 - "$source_file" "${SIMD_ELEMENT_TYPE_MUTATION_RUN:-}" <<'PY'
from pathlib import Path
import sys

source = Path(sys.argv[1]).read_text(encoding="utf-8")
start = source.index("(eval-when (:compile-toplevel :load-toplevel :execute)")
end = source.index("\n\n(defun simd-pack-total-size", start)
form = source[start:end]
if sys.argv[2]:
    form = form.replace("(plusp width)", "(zerop width)", 1)
required = [
    "(defun resolve-simd-integer-element-type",
    "(plusp width)",
    "(multiple-value-bind (kind width)",
    "(setf (ldb +simd-pack-element-type+ header) kind",
]
missing = [token for token in required if token not in form]
if missing:
    raise SystemExit("SIMD element-type resolution contract missing: " + ", ".join(missing))
if "TODO: Make this a bit more clever resolving the element-type" in form:
    raise SystemExit("SIMD element-type resolution TODO remains")
print("SIMD element-type resolution contract passed")
PY

if [[ -z "${SIMD_ELEMENT_TYPE_MUTATION_RUN:-}" ]]; then
  if SIMD_ELEMENT_TYPE_MUTATION_RUN=1 bash "$0" >/dev/null 2>&1; then
    echo "SIMD element-type mutation unexpectedly survived" >&2
    exit 1
  fi
  echo "SIMD element-type mutation rejected"
fi
