#!/usr/bin/env bash
# Regression coverage for separating the initial readtable from the standard one.
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "$script_dir/../.." && pwd)
source_file=${READER_SOURCE:-"$repo_root/system/reader.lisp"}

python3 - "$source_file" "${READER_STANDARD_COPY_MUTATION_RUN:-}" <<'PY'
from pathlib import Path
import sys

source = Path(sys.argv[1]).read_text(encoding="utf-8")
start = source.index("(initialize-standard-readtable *standard-readtable*)")
form = source[start:]
if sys.argv[2]:
    form = form.replace("(setf *readtable* (copy-readtable nil))", "", 1)

required = [
    "(initialize-standard-readtable *standard-readtable*)",
    "(setf *readtable* (copy-readtable nil))",
]
missing = [token for token in required if token not in form]
if "TODO: At some point the init code must copy the standard readtable" in source:
    missing.append("TODO marker removal")
if missing:
    raise SystemExit("reader standard-copy contract missing: " + ", ".join(missing))
print("reader standard-copy contract passed")
PY

if [[ -z "${READER_STANDARD_COPY_MUTATION_RUN:-}" ]]; then
  if READER_STANDARD_COPY_MUTATION_RUN=1 bash "$0" >/dev/null 2>&1; then
    echo "reader standard-copy mutation unexpectedly survived" >&2
    exit 1
  fi
  echo "reader standard-copy mutation rejected"
fi
