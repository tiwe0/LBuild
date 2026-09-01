#!/usr/bin/env bash
set -euo pipefail
script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "$script_dir/../.." && pwd)
source_file=${LAP_ARM64_SOURCE:-"$repo_root/compiler/lap-arm64.lisp"}
python3 - "$source_file" "${LAP_ARM64_MASK_MUTATION_RUN:-}" <<'PY'
from pathlib import Path
import sys
s=Path(sys.argv[1]).read_text()
if sys.argv[2]: s=s.replace("(assert rotated ()", "(assert nil ()", 1)
required=["(loop while (< rotation reg-size)", "(logior (ash imm (- rotation))", "(assert rotated ()", "(mod (+ rotation shift) reg-size)"]
missing=[x for x in required if x not in s]
if "TODO: Support masks that wrap." in s: missing.append("TODO marker removal")
if missing: raise SystemExit("ARM64 wrapping-mask contract missing: "+", ".join(missing))
print("ARM64 wrapping-mask contract passed")
PY
if [[ -z "${LAP_ARM64_MASK_MUTATION_RUN:-}" ]]; then
  if LAP_ARM64_MASK_MUTATION_RUN=1 bash "$0" >/dev/null 2>&1; then
    echo "ARM64 wrapping-mask mutation unexpectedly survived" >&2; exit 1
  fi
  echo "ARM64 wrapping-mask mutation rejected"
fi
