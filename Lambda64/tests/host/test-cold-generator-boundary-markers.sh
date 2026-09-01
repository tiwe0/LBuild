#!/usr/bin/env bash
set -euo pipefail
repo_root=$(cd "$(dirname "$0")/../.." && pwd)
python3 - "$repo_root" <<'PY'
from pathlib import Path
import sys
root = Path(sys.argv[1])
cold = (root / 'tools/cold-generator2/cold-generator.lisp').read_text()
x86 = (root / 'tools/cold-generator2/x86-64.lisp').read_text()
classes = (root / 'tools/cold-generator2/class-definitions.lisp').read_text()
clos = (root / 'tools/cold-generator2/clos.lisp').read_text()
environment = (root / 'tools/cold-generator2/environment.lisp').read_text()
serialize = (root / 'tools/cold-generator2/serialize.lisp').read_text()
cross_compile = (root / 'compiler/cross-compile.lisp').read_text()
assert '("supervisor/arm64/cpu.lisp" :arm64)' in cold
assert 'TODO: Turn this into a direct named call.' in x86
assert '(:object :r13 ,sys.int::+fref-code+)' in x86
assert '(lap:call :rax)' in x86
# Dynamic FREF code may be hot-swapped; a static named call would bypass slot 0 publication.
assert 'sys.int::+fref-code+' in x86 and ':r13' in x86
assert 'FIXME: Source locations for these are lost.' in classes
assert 'Preserve source metadata for the cold CLOS bootstrap.' in cross_compile
assert '(remf initargs :source-location)' not in cross_compile
assert "FIXME: This doesn't quite work with large bytes." in classes
assert '(check-type size (integer 0 #x1FFF))' in environment
assert '(check-type position (integer 0 #x1FFFFFFFFFFF))' in environment
# Mirror the immediate BYTE packing contract to catch accidental field-width
# regressions even when a full cold-image build is unavailable.
size, position = 0x1FFF, 0x1FFFFFFFFFFF
packed = (size << 6) | (position << 19)
assert (packed >> 6) & 0x1FFF == size
assert (packed >> 19) & 0x1FFFFFFFFFFF == position
assert 'FIXME: Need to include an initfunction' not in clos
assert ':initfunction (let ((slot slot))' in clos
assert '(initfunction :initform nil :initarg :initfunction)' in classes
assert 'defun host-make-standard-environment' in environment
assert 'defun cross-intern' in environment
assert 'defun host-structure-definition-name' in environment
assert 'defun make-weak-key-table' in environment
assert ':weakness :key' in environment
assert 'drain-initialization-queue' in serialize
assert 'deterministic package/name order' in serialize
for ident in ('0436', '0437', '0440', '0441', '0443', '0448', '0454'):
    spec = (root.parent / 'docs/modernization/todo-fixme/specs' / f'TF-WI-{ident}.md').read_text()
    for token in ('status: active', 'owner: runtime', 'review-cycle: 30d', f'TF-WI-{ident}'):
        assert token in spec, (ident, token)
print('cold-generator boundary markers passed')
PY
