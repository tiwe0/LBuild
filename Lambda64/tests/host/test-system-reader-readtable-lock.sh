#!/usr/bin/env bash
# Regression contract for serialized readtable access.
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "$script_dir/../.." && pwd)
source_file=${READER_LOCK_SOURCE:-"$repo_root/system/reader.lisp"}

python3 - "$source_file" "${READER_LOCK_MUTATION_RUN:-}" <<'PY'
from pathlib import Path
import sys

source = Path(sys.argv[1]).read_text(encoding="utf-8")
if sys.argv[2]:
    source = source.replace("(with-readtable-lock (readtable)", "(progn")

required = [
    "(lock nil)",
    "(defmacro with-readtable-lock",
    "(sys.int::cas (readtable-lock ,rt) nil t)",
    "(sys.int::atomic-swapf nil (readtable-lock ,rt))",
    "(with-readtable-lock (readtable)",
]
missing = [token for token in required if token not in source]
if "FIXME: A full lock around the readtable" in source:
    missing.append("FIXME marker removal")
if missing:
    raise SystemExit("reader readtable-lock contract missing: " + ", ".join(missing))
print("reader readtable-lock contract passed")
PY

if [[ -z "${READER_LOCK_MUTATION_RUN:-}" ]]; then
  if READER_LOCK_MUTATION_RUN=1 bash "$0" >/dev/null 2>&1; then
    echo "reader readtable-lock mutation unexpectedly survived" >&2
    exit 1
  fi
  echo "reader readtable-lock mutation rejected"
fi
