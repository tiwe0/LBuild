#!/usr/bin/env bash
# Regression coverage for full cdr-chain circularity checks in EQUAL hash keys.
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "$script_dir/../.." && pwd)
source_file=${HASH_TABLE_SOURCE:-"$repo_root/system/hash-table.lisp"}

python3 - "$source_file" "${HASH_TABLE_CIRCULARITY_MUTATION_RUN:-}" <<'PY'
from pathlib import Path
import re
import sys

source = Path(sys.argv[1]).read_text(encoding="utf-8")
start = source.index("(defun object-hash-gc-invariant-under-test")
end = source.index("\n\n(defun hash-table-size", start)
form = source[start:end]
if sys.argv[2]:
    form = re.sub(r"\(when \(eq slow fast\)\s*\(return nil\)\)", "", form, count=1)

required = [
    "(frob-list",
    "(cddr fast)",
    "(eq slow fast)",
    "(frob (car slow) (1- depth))",
]
missing = [token for token in required if token not in form]
if "TODO: Do the normal fast/slow circularity check" in form:
    missing.append("TODO marker removal")
if missing:
    raise SystemExit("hash-table circularity contract missing: " + ", ".join(missing))
print("hash-table circularity contract passed")
PY

if [[ -z "${HASH_TABLE_CIRCULARITY_MUTATION_RUN:-}" ]]; then
  if HASH_TABLE_CIRCULARITY_MUTATION_RUN=1 bash "$0" >/dev/null 2>&1; then
    echo "hash-table circularity mutation unexpectedly survived" >&2
    exit 1
  fi
  echo "hash-table circularity mutation rejected"
fi
