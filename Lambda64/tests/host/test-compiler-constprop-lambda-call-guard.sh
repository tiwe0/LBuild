#!/usr/bin/env bash
# Regression coverage for limiting propagated lambdas to FUNCALL.
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "$script_dir/../.." && pwd)
source_file=${CONSTPROP_SOURCE:-"$repo_root/compiler/constprop.lisp"}

python3 - "$source_file" "${CONSTPROP_LAMBDA_CALL_MUTATION_RUN:-}" <<'PY'
from pathlib import Path
import sys

source = Path(sys.argv[1]).read_text(encoding="utf-8")
if "should be careful to avoid propagating lambdas" in source:
    raise SystemExit("constprop still contains the unguarded lambda propagation FIXME")
required = [
    "*constprop-allow-lambda-propagation*",
    "(eql (name form) 'funcall)",
    "(not *constprop-allow-lambda-propagation*)",
    "(return-from cp-form form)",
]
if sys.argv[2]:
    source = source.replace("(eql (name form) 'funcall)", "t", 1)
missing = [token for token in required if token not in source]
if missing:
    raise SystemExit("constprop lambda-call guard contract missing: " + ", ".join(missing))
print("constprop lambda-call guard contract passed")
PY

if [[ -z "${CONSTPROP_LAMBDA_CALL_MUTATION_RUN:-}" ]]; then
  if CONSTPROP_LAMBDA_CALL_MUTATION_RUN=1 bash "$0" >/dev/null 2>&1; then
    echo "constprop lambda-call mutation unexpectedly survived" >&2
    exit 1
  fi
  echo "constprop lambda-call mutation rejected"
fi
