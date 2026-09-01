#!/usr/bin/env bash
# Regression coverage for ARM64 load/store immediate register width decoding.
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "$script_dir/../.." && pwd)
source_file=${DISASSEMBLE_SOURCE:-"$repo_root/system/disassemble-arm64.lisp"}

python3 - "$source_file" "${ARM64_REGISTER_MUTATION_RUN:-}" <<'PY'
from pathlib import Path
import sys

source = Path(sys.argv[1]).read_text(encoding="utf-8")
start = source.index("(defun load/store-register (context word)")
end = source.index("\n\n;; Load/store register (register offset)", start)
decoder = source[start:end]

if sys.argv[2]:
    # Simulate the baseline bug: every integer Rt is decoded as an X register.
    decoder = decoder.replace(
        "(if (or (eql size 3)\n                                               (eql opc 2))",
        "(if t ; mutation",
        1,
    )

required = [
    "(eql size 3)",
    "(eql opc 2)",
    "(decode-gp32 (ldb +rt+ word))",
]
missing = [token for token in required if token not in decoder]
if "FIXME: Register decode here is wrong" in decoder:
    missing.append("FIXME marker removal")
if missing:
    raise SystemExit("ARM64 load/store register-width contract missing: " + ", ".join(missing))
print("ARM64 load/store register-width contract passed")
PY

if [[ -z "${ARM64_REGISTER_MUTATION_RUN:-}" ]]; then
  if ARM64_REGISTER_MUTATION_RUN=1 bash "$0" >/dev/null 2>&1; then
    echo "ARM64 register decoder mutation unexpectedly survived" >&2
    exit 1
  fi
  echo "ARM64 register decoder mutation rejected"
fi
