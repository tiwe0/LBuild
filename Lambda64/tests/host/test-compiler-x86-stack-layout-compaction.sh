#!/usr/bin/env bash
set -euo pipefail
repo_root=$(cd "$(dirname "$0")/../.." && pwd)
source="$repo_root/compiler/backend/x86-64/codegen.lisp"
python3 - "$source" <<'PY'
from pathlib import Path
import sys
text = Path(sys.argv[1]).read_text()
assert 'TODO: Sort the layout so stack slots for values are all together and trim' not in text
for token in ('defun compact-stack-layout',
              'Group pointer spill slots before raw slots',
              'spill-locations',
              'GC/debug slot indices are remapped together'):
    assert token in text, token
# Mutation guard: compaction must happen before backend-private prepass slots.
assert text.index('(compact-stack-layout stack-layout spill-locations') < text.index('(defun allocate-stack-slots')
PY
printf 'x86-64 stack-layout compaction checks passed\n'
