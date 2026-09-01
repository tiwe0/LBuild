#!/usr/bin/env bash
# Regression coverage for exact reader float conversion before coercion.
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "$script_dir/../.." && pwd)
source_file=${READER_SOURCE:-"$repo_root/system/reader.lisp"}

python3 - "$source_file" "${READER_FLOAT_MUTATION_RUN:-}" <<'PY'
from pathlib import Path
import sys

source = Path(sys.argv[1]).read_text(encoding="utf-8")
start = source.index("(defun read-float")
end = source.index("\n\n(defun read-integer", start)
form = source[start:end]
if sys.argv[2]:
    form = form.replace("(* integer-part 10)", "(* integer-part 10.0d0)", 1)
required = [
    "(setf integer-part (+ (* integer-part 10) weight))",
    "(decimal-part 0)",
    "(expt 10 (* exponent-sign exponent-value))",
    "(coerce",
    "(#\\S 'short-float)",
    "(#\\D 'double-float)",
]
missing = [token for token in required if token not in form]
if missing:
    raise SystemExit("reader float-selection contract missing: " + ", ".join(missing))
if "TODO, deal with float type selection correctly" in form:
    raise SystemExit("reader float-selection TODO remains")
print("reader float-selection contract passed")
PY

if [[ -z "${READER_FLOAT_MUTATION_RUN:-}" ]]; then
  if READER_FLOAT_MUTATION_RUN=1 bash "$0" >/dev/null 2>&1; then
    echo "reader float-selection mutation unexpectedly survived" >&2
    exit 1
  fi
  echo "reader float-selection mutation rejected"
fi
