#!/usr/bin/env bash
# Contract test for atomic pprint-dispatch table reads and mutations.
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "$script_dir/../.." && pwd)
source_file=${XP_SOURCE:-"$repo_root/system/xp.lisp"}

python3 - "$source_file" "${XP_DISPATCH_LOCK_MUTATION_RUN:-}" <<'PY'
from pathlib import Path
import sys

source = Path(sys.argv[1]).read_text(encoding="utf-8")
if sys.argv[2]:
    # Simulate a regression deleting the table-level lock from one operation.
    source = source.replace(
        "(mezzano.supervisor:with-mutex ((pprint-dispatch-table-lock table))",
        "(progn",
        1,
    )
required = [
    "(lock :initarg :lock :accessor pprint-dispatch-table-lock)",
    ":lock (mezzano.supervisor:make-mutex 'pprint-dispatch-table)",
]
missing = [token for token in required if token not in source]
for name in ("copy-pprint-dispatch", "set-pprint-dispatch+", "get-printer"):
    start = source.index(f"(defun {name}")
    end = source.find("\n(defun ", start + 1)
    form = source[start:] if end < 0 else source[start:end]
    if "(mezzano.supervisor:with-mutex ((pprint-dispatch-table-lock table))" not in form:
        missing.append(f"{name} lock")
if missing:
    raise SystemExit("pprint dispatch lock contract missing: " + ", ".join(missing))
print("pprint dispatch lock contract passed")
PY

if [[ -z "${XP_DISPATCH_LOCK_MUTATION_RUN:-}" ]]; then
  if XP_DISPATCH_LOCK_MUTATION_RUN=1 bash "$0" >/dev/null 2>&1; then
    echo "pprint dispatch lock mutation unexpectedly survived" >&2
    exit 1
  fi
  echo "pprint dispatch lock mutation rejected"
fi
