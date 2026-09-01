#!/usr/bin/env bash
# Regression coverage for ARM64 register-offset address scaling.
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "$script_dir/../.." && pwd)
source_file=${DISASSEMBLE_SOURCE:-"$repo_root/system/disassemble-arm64.lisp"}

python3 - "$source_file" "${ARM64_OFFSET_MUTATION_RUN:-}" <<'PY'
from pathlib import Path
import sys

source = Path(sys.argv[1]).read_text(encoding="utf-8")
start = source.index("(defun load/store-register-register-offset (context word)")
end = source.index("\n\n;; Load/store register (unsigned immediate)", start)
decoder = source[start:end]

if sys.argv[2]:
    # Simulate the pre-fix bugs: Q offsets use raw size and Rt is always X.
    decoder = decoder.replace(
        "(if s\n                                     scale\n                                     0)",
        "(if s\n                                     size\n                                     0)",
        1,
    )
    decoder = decoder.replace(
        "(if (or (eql size 3)\n                                               (eql opc 2))\n                                           (decode-gp64 (ldb +rt+ word))\n                                           (decode-gp32 (ldb +rt+ word)))",
        "(decode-gp64 (ldb +rt+ word))",
        1,
    )

required = [
    "(scale (if (and simd&fp (logbitp 1 opc))",
    "(+ size 4)",
    "                                     scale",
    "(decode-fp (ldb +rt+ word) fp-type)",
    "(decode-gp32 (ldb +rt+ word))",
]
missing = [token for token in required if token not in decoder]
if "FIXME: Address decode here is wrong" in decoder:
    missing.append("FIXME marker removal")
if missing:
    raise SystemExit("ARM64 register-offset address contract missing: " + ", ".join(missing))
print("ARM64 register-offset address scaling contract passed")
PY

if [[ -z "${ARM64_OFFSET_MUTATION_RUN:-}" ]]; then
  if ARM64_OFFSET_MUTATION_RUN=1 bash "$0" >/dev/null 2>&1; then
    echo "ARM64 register-offset decoder mutation unexpectedly survived" >&2
    exit 1
  fi
  echo "ARM64 register-offset decoder mutation rejected"
fi
