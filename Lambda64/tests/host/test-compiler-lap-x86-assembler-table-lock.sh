#!/usr/bin/env bash
set -euo pipefail
script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "$script_dir/../.." && pwd)
source_file=${LAP_X86_SOURCE:-"$repo_root/compiler/lap-x86.lisp"}
python3 - "$source_file" "${LAP_X86_TABLE_MUTATION_RUN:-}" <<'PY'
from pathlib import Path
import sys
s=Path(sys.argv[1]).read_text()
if sys.argv[2]: s=s.replace(":synchronized t", ":synchronized nil", 1)
required=["(make-hash-table :synchronized t :enforce-gc-invariant-keys t)", "Definitions may be registered"]
missing=[x for x in required if x not in s]
if "FIXME: This is not entirely correct" in s: missing.append("FIXME marker removal")
if missing: raise SystemExit("x86 assembler-table lock contract missing: "+", ".join(missing))
print("x86 assembler-table synchronization contract passed")
PY
if [[ -z "${LAP_X86_TABLE_MUTATION_RUN:-}" ]]; then
  if LAP_X86_TABLE_MUTATION_RUN=1 bash "$0" >/dev/null 2>&1; then
    echo "x86 assembler-table mutation unexpectedly survived" >&2; exit 1
  fi
  echo "x86 assembler-table mutation rejected"
fi
