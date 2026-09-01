#!/usr/bin/env bash
# Regression coverage for Unicode-aware reader invalid-character checks.
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "$script_dir/../.." && pwd)
source_file=${READER_SOURCE:-"$repo_root/system/reader.lisp"}

python3 - "$source_file" "${READER_UNICODE_INVALID_MUTATION_RUN:-}" <<'PY'
from pathlib import Path
import sys

source = Path(sys.argv[1]).read_text(encoding="utf-8")
marker = "(defun invalidp"
start = source.index(marker)
end = source.index("\n\n(defun decimal-point-p", start)
form = source[start:end]
if sys.argv[2]:
    form = form.replace("(not (graphic-char-p char))", "(member char '(#\\Backspace #\\Tab #\\Newline))", 1)

required = [
    "(eql (readtable-syntax-type char readtable) nil)",
    "(not (graphic-char-p char))",
]
missing = [token for token in required if token not in form]
if "TODO: Unicode awareness." in form:
    missing.append("TODO marker removal")
if missing:
    raise SystemExit("reader Unicode-invalid contract missing: " + ", ".join(missing))
print("reader Unicode-invalid contract passed")
PY

if [[ -z "${READER_UNICODE_INVALID_MUTATION_RUN:-}" ]]; then
  if READER_UNICODE_INVALID_MUTATION_RUN=1 bash "$0" >/dev/null 2>&1; then
    echo "reader Unicode-invalid mutation unexpectedly survived" >&2
    exit 1
  fi
  echo "reader Unicode-invalid mutation rejected"
fi
