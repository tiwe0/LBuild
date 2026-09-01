#!/usr/bin/env bash
set -euo pipefail

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/../.." && pwd)
source_file=${STORE_SOURCE:-"$repo_root/supervisor/store.lisp"}

python3 - "$source_file" <<'PY'
from pathlib import Path
import re, sys

source = Path(sys.argv[1]).read_text()
start = source.index("(defun regenerate-store-freelist")
tail = source[start:]
depth = 0
end = None
for i, c in enumerate(tail):
    if c == "(": depth += 1
    elif c == ")":
        depth -= 1
        if depth == 0:
            end = start + i + 1
            break
assert end is not None, "unterminated regenerate-store-freelist"
form = source[start:end]

# Every allocated page/block left on FREE-BLOCK-LIST after serializing the
# used list must be reclaimed; ESTIMATED-COUNT intentionally over-allocates.
cleanup = re.compile(
    r"\(loop\s+\(when \(not free-block-list\).*?\(free-page page\).*?\(store-free block 1\)\)\)",
    re.S,
)
match = cleanup.search(form)
assert match, "regenerate-store-freelist lacks unused block/page cleanup loop"
assert form.index(";; Freelist is back to normal") < match.start(), "cleanup loop is not in finalization path"

# Mutation-aware: deleting the cleanup loop must invalidate the contract.
mutated = form[:match.start()] + form[match.end():]
assert not cleanup.search(mutated), "mutation did not remove cleanup loop"
print("store regenerate freelist cleanup contract passed (mutation-aware)")
PY
