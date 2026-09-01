#!/usr/bin/env bash
set -euo pipefail
repo_root=$(cd "$(dirname "$0")/../.." && pwd)
source="$repo_root/compiler/backend/arm64/memory.lisp"
spec="$repo_root/../docs/modernization/todo-fixme/specs/TF-WI-0017.md"
python3 - "$source" "$spec" <<'PY'
from pathlib import Path
import sys
source = Path(sys.argv[1]).read_text()
spec = Path(sys.argv[2]).read_text()
for token in ('(define-builtin (sys.int::dcas sys.int::%memref-t)',
              'arm64-dcas-mem-instruction', ':old-1 old-1', ':old-2 old-2',
              ':new-1 new-1', ':new-2 new-2', ':current-1 current-1',
              ':current-2 current-2', 'with-scaled-fixnum-index (scaled-index index 8)'):
    assert token in source, token
backend = Path(sys.argv[1]).with_name('arm64.lisp').read_text()
codegen = Path(sys.argv[1]).with_name('codegen.lisp').read_text()
for token in ('defclass arm64-dcas-mem-instruction', "'(:x0 :x2 :x3 :x6 :x7)"):
    assert token in backend, token
for token in ('lap:caspal :x2 :x6', 'arm64-dcas-current-1',
              'arm64-dcas-current-2', 'lap:csel.eq :x0 :x0 :x26'):
    assert token in codegen, token
for token in ('casp[a][l]', '128-bit\ncompare-exchange IR instruction',
              'arbitrary address', '16-byte alignment', 'misaligned', 'arm64-cas-mem-instruction',
              'no clobbers', 'fixed adjacent registers', 'incorrect GC maps'):
    assert token in spec, token
PY
printf 'ARM64 memref DCAS boundary checks passed\n'
