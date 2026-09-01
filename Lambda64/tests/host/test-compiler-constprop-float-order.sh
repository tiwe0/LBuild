#!/usr/bin/env bash
# Regression coverage for preserving floating-point operand order in constprop.
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "$script_dir/../.." && pwd)
source_file=${CONSTPROP_SOURCE:-"$repo_root/compiler/constprop.lisp"}

python3 - "$source_file" "${CONSTPROP_FLOAT_ORDER_MUTATION_RUN:-}" <<'PY'
from pathlib import Path
import sys

source = Path(sys.argv[1]).read_text(encoding="utf-8")
if "Float arithemetic is non-commutative." in source:
    raise SystemExit("constprop still documents unsafe floating-point reordering")
required = [
    "(defun commutative-fold-safe-p",
    "(commutative-fold-safe-p arg-list)",
    "(compiler-valid-not-subtypep type 'float)",
    "(every (lambda (arg) (typep (unwrap-the arg) 'ast-quote)) arg-list)",
]
if sys.argv[2]:
    source = source.replace("(commutative-fold-safe-p arg-list)", "t", 1)
missing = [token for token in required if token not in source]
if missing:
    raise SystemExit("constprop float-order guard contract missing: " + ", ".join(missing))
print("constprop floating-point order contract passed")
PY

if [[ -z "${CONSTPROP_FLOAT_ORDER_MUTATION_RUN:-}" ]]; then
  if CONSTPROP_FLOAT_ORDER_MUTATION_RUN=1 bash "$0" >/dev/null 2>&1; then
    echo "constprop float-order mutation unexpectedly survived" >&2
    exit 1
  fi
  echo "constprop float-order mutation rejected"
fi
