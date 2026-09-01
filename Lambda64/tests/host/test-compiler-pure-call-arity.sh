#!/usr/bin/env bash
# Regression coverage for PURE-P rejecting unsupported pure-call arities.
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "$script_dir/../.." && pwd)
source_file=${PURE_CALL_ARITY_SOURCE:-"$repo_root/compiler/simplify.lisp"}

python3 - "$source_file" "${PURE_CALL_ARITY_MUTATION_RUN:-}" <<'PY'
from pathlib import Path
import sys

source = Path(sys.argv[1]).read_text(encoding="utf-8")
if "This needs to check the number of arguments" in source:
    raise SystemExit("pure-p still contains the argument-count FIXME")
required = [
    "(defun pure-function-arity-p",
    "(= argument-count 1)",
    "(= argument-count 2)",
    "((list)\n     t)",
    "((list*)\n     (plusp argument-count))",
    "(pure-function-arity-p (ast-name unwrapped)",
    "(length (ast-arguments unwrapped))",
]
if sys.argv[2]:
    anchor = "(pure-function-arity-p (ast-name unwrapped)"
    if anchor not in source:
        raise SystemExit("pure-p arity-check mutation anchor missing")
    source = source.replace(anchor, "(progn t) ; mutation", 1)
missing = [token for token in required if token not in source]
if missing:
    raise SystemExit("pure-p argument-count contract missing: " + ", ".join(missing))
print("pure-p call arity contract passed")
PY

if [[ -z "${PURE_CALL_ARITY_MUTATION_RUN:-}" ]]; then
  if PURE_CALL_ARITY_MUTATION_RUN=1 bash "$0" >/dev/null 2>&1; then
    echo "pure-p call arity mutation unexpectedly survived" >&2
    exit 1
  fi
  echo "pure-p call arity mutation rejected"
fi
