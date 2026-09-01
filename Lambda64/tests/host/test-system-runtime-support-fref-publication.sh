#!/usr/bin/env bash
# Host contract for serialized, ordered FREF publication.
set -euo pipefail
root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
python3 - "$root/system/runtime-support.lisp" <<'PY'
from pathlib import Path
import sys
s = Path(sys.argv[1]).read_text()
assert '(defglobal *function-reference-lock* :unlocked)' in s
start = s.index('(defun (setf function-reference-function)')
form = s[start:s.index('\n(defun trace-wrapper-p', start)]
assert 'safe-without-interrupts' in form
assert 'with-symbol-spinlock (*function-reference-lock*)' in form
assert 'FIXME: FREF should be locked' not in form
assert 'FIXME: Cross-CPU synchronization' not in form
assert form.count('sys.int::dma-write-barrier') == 3
assert form.count('%synchronize-function-reference fref') == 3
for branch in ('((not value)', '((%object-of-type-p value', '(t'):
    b = form[form.index(branch):]
    assert b.index('(%object-ref-t fref +fref-function+)') < b.index('sys.int::dma-write-barrier')
    assert b.index('%activate-function-reference') < b.index('%synchronize-function-reference fref')
print('function-reference publication protocol passed')
PY
