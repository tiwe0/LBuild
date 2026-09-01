#!/usr/bin/env bash
set -euo pipefail
script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "$script_dir/../.." && pwd)
source_file=${FAST_CLASS_HASH_SOURCE:-"$repo_root/system/clos/fast-class-hash-table.lisp"}
python3 - "$source_file" "${FAST_CLASS_HASH_PRUNE_MUTATION_RUN:-}" <<'PY'
from pathlib import Path
import sys

source = Path(sys.argv[1]).read_text(encoding="utf-8")
if sys.argv[2]:
    source = source.replace("(%prune-fast-class-hash-table table)", "nil", 1)
required = [
    "(defun %prune-fast-class-hash-table",
    "(fast-class-hash-table-count table) 0",
    "(setf (svref storage index) t)",
    "(decf (fast-class-hash-table-count table))",
    "  (%prune-fast-class-hash-table table)",
]
missing = [x for x in required if x not in source]
if "TODO: Be smarter/more proactive pruning dead weak pointers" in source:
    missing.append("TODO marker removal")
if missing:
    raise SystemExit("fast-class-hash pruning contract missing: " + ", ".join(missing))
print("fast-class-hash pruning contract passed")
PY
if [[ -z "${FAST_CLASS_HASH_PRUNE_MUTATION_RUN:-}" ]]; then
  if FAST_CLASS_HASH_PRUNE_MUTATION_RUN=1 bash "$0" >/dev/null 2>&1; then
    echo "fast-class-hash pruning mutation unexpectedly survived" >&2
    exit 1
  fi
  echo "fast-class-hash pruning mutation rejected"
fi
