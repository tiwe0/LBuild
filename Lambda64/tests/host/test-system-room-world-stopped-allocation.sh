#!/usr/bin/env bash
# ROOM walks the heap with the world stopped and must not allocate there.
#
# AREA-INFO's callback runs inside CALL-WITH-WORLD-STOPPED.  Any allocation on
# that path enters a pseudo-atomic region and panics with "Going PA with world
# stopped!".  The obvious allocations were already hoisted out (ALLOCATED-CLASSES
# is pre-sized and only shifted), but the BSEARCH call still went through a
# keyword lambda list, which materialises an argument vector in the general
# area.  Keep that path on the positional entry point.
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "$script_dir/../.." && pwd)

python3 - "$repo_root" "${ROOM_ALLOC_MUTATION_RUN:-}" <<'PY'
from pathlib import Path
import re, sys

root = Path(sys.argv[1])
room = (root / "system/room.lisp").read_text(encoding="utf-8")
stuff = (root / "system/stuff.lisp").read_text(encoding="utf-8")
if sys.argv[2]:
    room = room.replace("(%bsearch address allocated-classes\n                                       0 nil 2 #'class-address)",
                        "(bsearch address allocated-classes\n                                      :stride 2 :key #'class-address)", 1)

if not re.search(r"\(defun %bsearch \(item vector start end stride key\)", stuff):
    raise SystemExit("%BSEARCH positional entry point is missing")

start = room.index("(defun area-info")
end = room.index("\n(defun ", start + 10)
body = room[start:end]

# No keyword-argument call may appear on the world-stopped walk.
for m in re.finditer(r"\((bsearch|make-array|make-simple-vector)\b[^\n]*", body):
    call = m.group(0)
    if m.group(1) == "make-array" and "allocated-classes" in body[:m.start()][-400:]:
        continue  # pre-allocated before the walk; checked below
    if m.group(1) == "bsearch":
        raise SystemExit(
            "AREA-INFO calls keyword BSEARCH inside the world-stopped walk; "
            "use %BSEARCH")

# The class vector must still be pre-allocated outside the walk.
if "(make-array 1000 :fill-pointer 0)" not in body:
    raise SystemExit("ALLOCATED-CLASSES is no longer pre-allocated")
print("room world-stopped allocation contract passed")
PY

if [[ -z "${ROOM_ALLOC_MUTATION_RUN:-}" ]]; then
  if ROOM_ALLOC_MUTATION_RUN=1 bash "$0" >/dev/null 2>&1; then
    echo "room allocation mutation unexpectedly survived" >&2
    exit 1
  fi
  echo "room allocation mutation rejected"
fi
