#!/usr/bin/env bash
set -euo pipefail
repo_root=$(cd "$(dirname "$0")/../.." && pwd)
source="$repo_root/compiler/backend/arm64/codegen.lisp"
python3 - "$source" <<'PY'
from pathlib import Path
import sys
text = Path(sys.argv[1]).read_text()
assert 'TODO: Sort the layout so stack slots for values are all together and trim' not in text
for token in ('defun compact-stack-layout',
              'Group pointer spill slots before raw slots',
              'spill-locations',
              'Slot zero (the &REST count) stays fixed',
              'GC/debug offsets remain coherent'):
    assert token in text, token
# Mutation guard: compaction must happen before backend-private prepass slots.
assert text.index('(compact-stack-layout stack-layout spill-locations') < text.index('(defun allocate-stack-slots')
PY
printf 'ARM64 stack-layout compaction checks passed\n'
