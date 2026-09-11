#!/usr/bin/env bash
# Host contract for serialized, ordered FREF publication.
set -euo pipefail
root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
python3 - "$root/system/runtime-support.lisp" <<'PY'
from pathlib import Path
import sys
s = Path(sys.argv[1]).read_text()
assert '(defglobal *function-reference-lock* :unlocked)' in s
# The three publication branches live in %PUBLISH-FUNCTION-REFERENCE-FUNCTION;
# the setter calls it under the writer spinlock.  Span both so the ordering
# contract is checked wherever it is spelled.
setter_start = s.index('(defun (setf function-reference-function)')
helper_start = s.index('(defun %publish-function-reference-function')
assert '%publish-function-reference-function' in s[setter_start:], \
    'setter must delegate to the publication helper'
start = min(setter_start, helper_start)
form = s[start:s.index('\n(defun trace-wrapper-p', setter_start)]
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
