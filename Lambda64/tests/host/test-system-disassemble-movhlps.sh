#!/usr/bin/env bash
# Regression coverage for MOVHLPS register versus MOVLPS memory decoding.
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "$script_dir/../.." && pwd)
source_file=${DISASSEMBLE_SOURCE:-"$repo_root/system/disassemble-x86-64.lisp"}

python3 - "$source_file" "${MOVHLPS_MUTATION_RUN:-}" <<'PY'
from pathlib import Path
import sys

source = Path(sys.argv[1]).read_text(encoding="utf-8")
start = source.index("(defun decode-movhlps")
end = source.index("\n\n(defun decode-v-w-ib", start)
decoder = source[start:end]

if sys.argv[2]:
    # Simulate the old bug: classify every R/M operand as a register.
    decoder = decoder.replace("(if (integerp r/m)", "(if t")

required = [
    "(defun decode-movhlps (context info)",
    "(integerp r/m)",
    "'sys.lap-x86:movhlps",
    "'sys.lap-x86::movlps",
    "(decode-xmm r/m (rex-b info))",
]
missing = [token for token in required if token not in decoder]
table_entry = "(decode-movhlps) ; 12: MOVHLPS (register) or MOVLPS (memory)"
if table_entry not in source:
    missing.append("MOVHLPS decoder table entry")
if "MOVHLPS, if the R/M operand is memory" in source:
    missing.append("FIXME marker removal")
if missing:
    raise SystemExit("MOVHLPS/MOVLPS decode contract missing: " + ", ".join(missing))
print("MOVHLPS/MOVLPS decode contract passed")
PY

if [[ -z "${MOVHLPS_MUTATION_RUN:-}" ]]; then
  if MOVHLPS_MUTATION_RUN=1 bash "$0" >/dev/null 2>&1; then
    echo "MOVHLPS decoder mutation unexpectedly survived" >&2
    exit 1
  fi
  echo "MOVHLPS decoder mutation rejected"
fi
