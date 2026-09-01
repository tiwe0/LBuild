#!/usr/bin/env bash
# Regression coverage for nested SIMD immediate dispatch.
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "$script_dir/../.." && pwd)
source_file=${SIMD_ARM64_SOURCE:-"$repo_root/runtime/simd-arm64.lisp"}

python3 - "$source_file" "${SIMD_NESTED_IMMEDIATES_MUTATION_RUN:-}" <<'PY'
from pathlib import Path
import sys

source = Path(sys.argv[1]).read_text(encoding="utf-8")
marker = "(defmacro define-op"
start = source.index(marker)
end = source.index("\n\n(defmacro %define-aref-transforms", start)
form = source[start:end]
if sys.argv[2]:
    form = form.replace("(position-if #'immediatep types)", "nil", 1)
required = [
    "(labels ((emit-immediate-switch",
    "(position-if #'immediatep types)",
    "(emit-immediate-switch value-names value-types)",
    "(immediate-max imm-type)",
]
missing = [token for token in required if token not in form]
if missing:
    raise SystemExit("SIMD nested-immediate contract missing: " + ", ".join(missing))
print("SIMD nested-immediate dispatch contract passed")
PY

if [[ -z "${SIMD_NESTED_IMMEDIATES_MUTATION_RUN:-}" ]]; then
  if SIMD_NESTED_IMMEDIATES_MUTATION_RUN=1 bash "$0" >/dev/null 2>&1; then
    echo "SIMD nested-immediate mutation unexpectedly survived" >&2
    exit 1
  fi
  echo "SIMD nested-immediate mutation rejected"
fi
