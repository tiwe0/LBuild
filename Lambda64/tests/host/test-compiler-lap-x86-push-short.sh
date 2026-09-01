#!/usr/bin/env bash
set -euo pipefail
script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "$script_dir/../.." && pwd)
source_file=${LAP_X86_SOURCE:-"$repo_root/compiler/lap-x86.lisp"}
python3 - "$source_file" "${LAP_X86_PUSH_SHORT_MUTATION_RUN:-}" <<'PY'
from pathlib import Path
import sys
s=Path(sys.argv[1]).read_text()
if sys.argv[2]: s=s.replace("(emit #x6A)", "(emit #x68)", 1)
required=["(typep resolved '(signed-byte 8))", "(emit #x6A)", "(emit-imm-with-relocation 1 resolved)"]
missing=[x for x in required if x not in s]
if "TODO: short form." in s: missing.append("TODO marker removal")
if missing: raise SystemExit("push short-form contract missing: "+", ".join(missing))
print("x86 push imm8 short-form contract passed")
PY
if [[ -z "${LAP_X86_PUSH_SHORT_MUTATION_RUN:-}" ]]; then
  if LAP_X86_PUSH_SHORT_MUTATION_RUN=1 bash "$0" >/dev/null 2>&1; then
    echo "x86 push short-form mutation unexpectedly survived" >&2; exit 1
  fi
  echo "x86 push short-form mutation rejected"
fi
