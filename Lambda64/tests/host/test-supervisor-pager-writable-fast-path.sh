#!/usr/bin/env bash
set -euo pipefail

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/../.." && pwd)
source_file=${PAGER_SOURCE:-"$repo_root/supervisor/pager.lisp"}

python3 - "$source_file" <<'PY'
from pathlib import Path
import re, sys

source = Path(sys.argv[1]).read_text()
start = source.index("(defun wait-for-page-fast-path")
tail = source[start:]
depth = 0
end = None
for i, c in enumerate(tail):
    if c == "(":
        depth += 1
    elif c == ")":
        depth -= 1
        if depth == 0:
            end = start + i + 1
            break
assert end is not None
form = source[start:end]

# The permission guard must precede the zero-fill fast path.  Without it, a
# write fault on a read-only zero-fill block is reported as handled after a
# read-only PTE is installed, causing a retry loop instead of an access fault.
guard = re.compile(
    r"\(when \(and block-info\s+writep\s+\(not \(block-info-writable-p block-info\)\)\)\s+"
    r"\(return-from wait-for-page-fast-path nil\)", re.S)
guard_match = guard.search(form)
assert guard_match, "fast path lacks read-only write-fault guard"
zero_path = form.index("Pager fast zero page mapping")
assert guard_match.start() < zero_path, "permission guard occurs after zero-fill path"

# Mutation check: deleting the guard must make this contract fail.
mutated = form[:guard_match.start()] + form[guard_match.end():]
assert not guard.search(mutated), "mutation did not remove the guarded behavior"
assert "Pager fast zero page mapping" in mutated
print("pager writable fast-path contract passed (mutation-aware)")
PY
