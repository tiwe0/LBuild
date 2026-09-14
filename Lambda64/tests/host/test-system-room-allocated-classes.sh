#!/usr/bin/env bash
# Regression coverage for address-ordered allocated class accounting.
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "$script_dir/../.." && pwd)
source_file=${ROOM_SOURCE:-"$repo_root/system/room.lisp"}

python3 - "$source_file" "${ROOM_ALLOCATED_CLASSES_MUTATION_RUN:-}" <<'PY'
from pathlib import Path
import re
import sys

source = Path(sys.argv[1]).read_text(encoding="utf-8")
start = source.index("(defun area-info")
end = source.index("\n\n(defun print-fragment-counts", start)
form = source[start:end]
if sys.argv[2]:
    form = re.sub(r"\(lisp-object-address class\)", "0", form, count=1)

required = [
    "(lisp-object-address class)",
    "(replace allocated-classes allocated-classes",
]
# The class vector is searched with a stride of two (address, count pairs).
# AREA-INFO runs inside CALL-WITH-WORLD-STOPPED, so it must call the positional
# %BSEARCH: the keyword form materialises its argument vector in the general
# area and allocating there panics with "Going PA with world stopped!".  Accept
# either spelling so the stride contract survives that change.
if not (re.search(r"\(bsearch\b[^)]*:stride\s+2", form, re.S)
        or re.search(r"\(%bsearch\b[^)]*\s2\s", form, re.S)):
    raise SystemExit(
        "room allocated-classes contract missing: stride-2 binary search")
missing = [token for token in required if token not in form]
if "TODO: Should keep this sorted by address" in form:
    missing.append("TODO marker removal")
if missing:
    raise SystemExit("room allocated-classes contract missing: " + ", ".join(missing))
print("room allocated-classes contract passed")
PY

if [[ -z "${ROOM_ALLOCATED_CLASSES_MUTATION_RUN:-}" ]]; then
  if ROOM_ALLOCATED_CLASSES_MUTATION_RUN=1 bash "$0" >/dev/null 2>&1; then
    echo "room allocated-classes mutation unexpectedly survived" >&2
    exit 1
  fi
  echo "room allocated-classes mutation rejected"
fi
