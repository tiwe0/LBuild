#!/usr/bin/env bash
# Regression coverage for ARM64 load-register-literal width/type decoding.
set -euo pipefail
script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "$script_dir/../.." && pwd)
source_file=${DISASSEMBLE_SOURCE:-"$repo_root/system/disassemble-arm64.lisp"}
python3 - "$source_file" "${ARM64_LITERAL_MUTATION_RUN:-}" <<'PY'
from pathlib import Path
import sys
source = Path(sys.argv[1]).read_text(encoding="utf-8")
start = source.index("(defun load-register-literal")
end = source.index("\n\n(defparameter *load/store-opcodes*", start)
decoder = source[start:end]
if sys.argv[2]:
    # Simulate the baseline bug: always decode Rt as X registers.
    decoder = decoder.replace("(decode-gp32 (ldb +rt+ word))", "(decode-gp64 (ldb +rt+ word))", 1)
required = [
    "(simd&fp (logbitp +v-bit+ word))",
    "(decode-gp32 (ldb +rt+ word))",
    "(decode-fp (ldb +rt+ word) type)",
    ":s", ":d", ":q",
    "'a64:ldrsw",
    ":load-register-literal-simd&fp-size",
]
missing = [token for token in required if token not in decoder]
if "FIXME: 32-bit and SIMD&FP versions" in decoder:
    missing.append("FIXME marker removal")
if missing:
    raise SystemExit("ARM64 literal decode contract missing: " + ", ".join(missing))
print("ARM64 load-register-literal contract passed")
PY
if [[ -z "${ARM64_LITERAL_MUTATION_RUN:-}" ]]; then
  if ARM64_LITERAL_MUTATION_RUN=1 bash "$0" >/dev/null 2>&1; then
    echo "ARM64 literal decoder mutation unexpectedly survived" >&2
    exit 1
  fi
  echo "ARM64 literal decoder mutation rejected"
fi
