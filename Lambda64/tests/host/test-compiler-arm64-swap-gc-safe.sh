#!/usr/bin/env bash
# Contract test for the ARM64 swap lowering's temporary stack slot.
set -euo pipefail
script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "$script_dir/../.." && pwd)
source_file=${ARM64_CODEGEN_SOURCE:-"$repo_root/compiler/backend/arm64/codegen.lisp"}

python3 - "$source_file" "${ARM64_SWAP_MUTATION_RUN:-}" <<'PY'
from pathlib import Path
import sys

source = Path(sys.argv[1]).read_text(encoding="utf-8")
prepass = "(defmethod lap-prepass (backend-function (instruction ir:swap-instruction)"
emit = "(defmethod emit-lap (backend-function (instruction ir:swap-instruction)"
for marker in (prepass, emit):
    if marker not in source:
        raise SystemExit(f"ARM64 swap method missing: {marker}")

if sys.argv[2]:
    # Ensure this test detects a regression back to an in-register XOR swap.
    source = source.replace("(emit-stack-store lhs temporary-slot)",
                            "(emit `(lap:eor ,lhs ,lhs ,rhs))", 1)

start = source.index(emit)
body = source[start:]
if "(emit-stack-store lhs temporary-slot)" not in body:
    raise SystemExit("swap must preserve lhs in a temporary stack slot")
if "(emit-stack-load rhs temporary-slot)" not in body:
    raise SystemExit("swap must restore lhs into rhs from the temporary slot")
if "lap:eor ,lhs" in body:
    raise SystemExit("unsafe XOR swap remains in ARM64 lowering")
if ":livep nil" not in source[source.index(prepass):start]:
    raise SystemExit("swap temporary slot must be marked raw/non-live")
print("ARM64 swap GC-safety contract passed")
PY

if [[ -z "${ARM64_SWAP_MUTATION_RUN:-}" ]]; then
  if ARM64_SWAP_MUTATION_RUN=1 bash "$0" >/dev/null 2>&1; then
    echo 'ARM64 swap mutation unexpectedly survived' >&2
    exit 1
  fi
  echo 'ARM64 swap mutation rejected'
fi
