#!/usr/bin/env bash
# Regression coverage for the reader's unified real-number validation.
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "$script_dir/../.." && pwd)
source_file=${READER_SOURCE:-"$repo_root/system/reader.lisp"}

python3 - "$source_file" "${READER_COMPLEX_REAL_MUTATION_RUN:-}" <<'PY'
from pathlib import Path
import sys

source = Path(sys.argv[1]).read_text(encoding="utf-8")
start = source.index("(defun read-#-complex")
end = source.index("\n\n(defun read-#-array", start)
form = source[start:end]
if sys.argv[2]:
    form = form.replace("(realp (first number))", "(or (short-float-p (first number)) (realp (first number)))", 1)

required = [
    "(realp (first number))",
    "(realp (second number))",
]
missing = [token for token in required if token not in form]
if "short-float-p" in form:
    missing.append("short-float special-case removal")
if "TODO: Clean this up, cross compiler hack." in form:
    missing.append("TODO marker removal")
if missing:
    raise SystemExit("reader complex-real contract missing: " + ", ".join(missing))
print("reader complex-real contract passed")
PY

if [[ -z "${READER_COMPLEX_REAL_MUTATION_RUN:-}" ]]; then
  if READER_COMPLEX_REAL_MUTATION_RUN=1 bash "$0" >/dev/null 2>&1; then
    echo "reader complex-real mutation unexpectedly survived" >&2
    exit 1
  fi
  echo "reader complex-real mutation rejected"
fi
