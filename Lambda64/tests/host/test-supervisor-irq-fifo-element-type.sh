#!/usr/bin/env bash
set -euo pipefail
script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "$script_dir/../.." && pwd)
source_file=${IRQ_FIFO_SOURCE:-"$repo_root/supervisor/sync.lisp"}
python3 - "$source_file" "${IRQ_FIFO_ELEMENT_TYPE_MUTATION_RUN:-}" <<'PY'
from pathlib import Path
import sys

s = Path(sys.argv[1]).read_text(encoding="utf-8")
start = s.index("(defun make-irq-fifo")
end = s.index("\n(defun irq-fifo-push", start)
f = s[start:end]
if sys.argv[2]:
    f = f.replace('(make-array size :element-type element-type :area :wired)',
                  '(sys.int::make-simple-vector size :wired)', 1)
required = [
    '(make-array size :element-type element-type :area :wired)',
    ':element-type (array-element-type buffer)',
]
missing = [x for x in required if x not in f]
if missing:
    raise SystemExit("IRQ FIFO element-type contract missing: " + ", ".join(missing))
if "make-simple-vector" in f:
    raise SystemExit("IRQ FIFO still allocates an untyped simple vector")
print("IRQ FIFO element-type allocation contract passed")
PY
if [[ -z "${IRQ_FIFO_ELEMENT_TYPE_MUTATION_RUN:-}" ]]; then
  if IRQ_FIFO_ELEMENT_TYPE_MUTATION_RUN=1 bash "$0" >/dev/null 2>&1; then
    echo "IRQ FIFO element-type mutation unexpectedly survived" >&2
    exit 1
  fi
  echo "IRQ FIFO element-type mutation rejected"
fi
