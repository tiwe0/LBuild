#!/usr/bin/env bash
# Regression contract for lock-free pruning of weak collection chains.
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "$script_dir/../.." && pwd)
source_file=${WEAK_OBJECTS_SOURCE:-"$repo_root/system/weak-objects.lisp"}

python3 - "$source_file" "${WEAK_OBJECTS_PRUNE_MUTATION_RUN:-}" <<'PY'
from pathlib import Path
import sys

source = Path(sys.argv[1]).read_text(encoding="utf-8")
if sys.argv[2]:
    source = source.replace("%prune-weak-pointer-chain", "%removed-prune-weak-pointer-chain")

required = [
    "(defun %prune-weak-pointer-chain",
    "(setf (cdr previous) (cdr node))",
    "(setf head (cdr node))",
    "(weak-list-objects weak-list)",
    "(weak-and-relation-objects weak-and-relation)",
    "(weak-or-relation-objects weak-or-relation)",
]
missing = [token for token in required if token not in source]
if "TODO: The weak collections should be modified" in source:
    missing.append("TODO marker removal")
if missing:
    raise SystemExit("weak-object pruning contract missing: " + ", ".join(missing))
print("weak-object pruning contract passed")
PY

if [[ -z "${WEAK_OBJECTS_PRUNE_MUTATION_RUN:-}" ]]; then
  if WEAK_OBJECTS_PRUNE_MUTATION_RUN=1 bash "$0" >/dev/null 2>&1; then
    echo "weak-object pruning mutation unexpectedly survived" >&2
    exit 1
  fi
  echo "weak-object pruning mutation rejected"
fi
