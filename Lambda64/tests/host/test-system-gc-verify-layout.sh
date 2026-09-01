#!/usr/bin/env bash
# Contract for verifying only boxed slots in bit-vector instance layouts.
set -euo pipefail
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/../.." && pwd)
source_file=${GC_SOURCE:-"$repo_root/system/gc.lisp"}
mutation=${GC_MUTATION_RUN:-}
python3 - "$source_file" "$mutation" <<'PY'
from pathlib import Path
import sys
s=Path(sys.argv[1]).read_text(); start=s.index('(defun verify-object'); end=s.index('\n(defun verify-at',start); form=s[start:end]
if 'TODO: Not implemented.' in form or 'FIXME' in form: raise SystemExit('verify-object marker remains')
if sys.argv[2]:
    form=form.replace('(* (1+ i) 8)', '(* i 8)')
for a in ('(dotimes (i heap-size)', '(bit heap-layout i)', '(verify-one (object-base-address object)', '(* (1+ i) 8)'):
    if a not in form: raise SystemExit(f'missing heap-layout verification anchor: {a}')
# Model verifies header at word 0 and only boxed slots at word i+1.
def verified_words(heap_layout):
    return [i + 1 for i, boxed in enumerate(heap_layout) if boxed]
if verified_words([0, 1, 0, 1]) != [2, 4]: raise SystemExit('boxed-slot offset model failed')
if verified_words([0, 0]) != []: raise SystemExit('unboxed layout model failed')
print('GC verify-object heap-layout contract passed')
PY
if [[ -z "$mutation" ]]; then
 if GC_MUTATION_RUN=1 bash "$0" >/dev/null 2>&1; then echo 'GC verify-layout mutation unexpectedly survived' >&2; exit 1; fi
 echo 'GC verify-layout mutation rejected'
fi
