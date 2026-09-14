#!/usr/bin/env bash
# Every *ALLOCATOR-LOCK* acquisition must go through WITH-ALLOCATOR-LOCK.
#
# The world stopper must take neither the allocator mutex nor a pseudo-atomic
# region: other threads are stopped, so a lock one of them owns is never
# released (the scheduler livelock watchdog reports "World stopper ... wait
# #<Mutex Allocator :Owner ...>"), and entering PA with the world stopped
# panics.  SNAPSHOT allocates while holding the world, so any acquisition site
# that skips the rule deadlocks the machine at the very end of boot.  The rule
# was originally written out in one of seven sites.
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "$script_dir/../.." && pwd)
source_file=${ALLOCATE_SOURCE:-"$repo_root/runtime/allocate.lisp"}

python3 - "$source_file" "${ALLOCATOR_LOCK_MUTATION_RUN:-}" <<'PY'
from pathlib import Path
import re, sys

source = Path(sys.argv[1]).read_text(encoding="utf-8")
if sys.argv[2]:
    # Historical shape: acquire the mutex directly at a call site.
    source = source.replace(
        "(defun %allocate-from-pinned-area-1 (tag data words)\n"
        "  ;; WITH-ALLOCATOR-LOCK already routes the world stopper past the lock.\n"
        "  (with-allocator-lock",
        "(defun %allocate-from-pinned-area-1 (tag data words)\n"
        "  (mezzano.supervisor:with-mutex (*allocator-lock*)", 1)

if "(defmacro with-allocator-lock" not in source:
    raise SystemExit("WITH-ALLOCATOR-LOCK is missing")
if "%world-stopper-p" not in source:
    raise SystemExit("the world-stopper predicate is missing")

macro_start = source.index("(defmacro with-allocator-lock")
macro_end = source.index("\n(defun ", macro_start)
macro = source[macro_start:macro_end]
if "%world-stopper-p" not in macro:
    raise SystemExit("WITH-ALLOCATOR-LOCK no longer bypasses the world stopper")
if "with-pseudo-atomic" not in macro:
    raise SystemExit("WITH-ALLOCATOR-LOCK no longer establishes pseudo-atomic")

# Outside the macro, nothing may name the mutex directly.
rest = source[:macro_start] + source[macro_end:]
stray = re.findall(r"with-mutex \(\*allocator-lock\*\)", rest)
if stray:
    raise SystemExit(
        f"{len(stray)} site(s) take *ALLOCATOR-LOCK* outside WITH-ALLOCATOR-LOCK; "
        "the world stopper would deadlock there")

uses = len(re.findall(r"\(with-allocator-lock\b", source))
print(f"allocator lock discipline contract passed ({uses} guarded sites)")
PY

if [[ -z "${ALLOCATOR_LOCK_MUTATION_RUN:-}" ]]; then
  if ALLOCATOR_LOCK_MUTATION_RUN=1 bash "$0" >/dev/null 2>&1; then
    echo "allocator lock discipline mutation unexpectedly survived" >&2
    exit 1
  fi
  echo "allocator lock discipline mutation rejected"
fi
