#!/usr/bin/env bash
set -euo pipefail

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/../.." && pwd)
source_file=${STORE_SOURCE:-"$repo_root/supervisor/store.lisp"}

python3 - "$source_file" <<'PY'
from pathlib import Path
import sys

source = Path(sys.argv[1]).read_text()
start = source.index("(defun store-deferred-free")
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
assert end is not None, "unterminated store-deferred-free"
form = source[start:end]

assert "(ensure (plusp n-blocks)" in form, "empty deferred ranges are not rejected"
assert "(freelist-metadata-free-p range)" in form, "main freelist free-bit guard missing"
assert "overlapping the free store" in form, "main freelist overlap failure missing"
assert "overlapping range" in form, "deferred-list overlap failure missing"
assert "(> range-start end)" in form, "deferred list is not traversed in start order"
assert "(freelist-metadata-end before) (freelist-metadata-end after)" in form, "adjacent ranges are not coalesced"
assert "(freelist-metadata-next previous) new" in form, "middle insertion does not link the predecessor"
assert "(freelist-metadata-next new) range" in form, "middle insertion does not link the successor"

# Mutation-aware checks: removing either overlap guard or sorted insertion
# logic must make this contract fail rather than silently passing.
without_main_guard = form.replace(
    '(when (and (freelist-metadata-free-p range)\n'
    '                 (< (freelist-metadata-start range) end)\n'
    '                 (< start (freelist-metadata-end range)))\n'
    '        (panic "Tried to defer a range overlapping the free store: " start "-" end))',
    '',
)
assert "overlapping the free store" not in without_main_guard, "main-overlap mutation was not applied"
without_sorted_guard = form.replace("((> range-start end) (return))", "(nil)")
assert "((> range-start end) (return))" not in without_sorted_guard, "sorted-order mutation was not applied"
assert "(> range-start end)" in form and "(> range-start end)" not in without_sorted_guard
without_middle_link = form.replace("(freelist-metadata-next previous) new", "(freelist-metadata-next previous) range")
assert "(freelist-metadata-next previous) new" not in without_middle_link, "middle-link mutation was not applied"
print("store deferred freelist overlap/order contract passed (mutation-aware)")
PY
