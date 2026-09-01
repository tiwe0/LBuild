#!/usr/bin/env bash
# Host contract for guarded unsigned range bounds checks.
set -euo pipefail
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/../.." && pwd)
source_file=${RUNTIME_SOURCE:-"$repo_root/runtime/runtime.lisp"}
mutation=${RUNTIME_MUTATION_RUN:-}
python3 - "$source_file" "$mutation" <<'PY'
from pathlib import Path
import sys
s=Path(sys.argv[1]).read_text()
start=s.index('(defun %bounds-check-range')
end=s.index('\n(declaim (inline %complex-bounds-check))', start)
form=s[start:end]
if 'TODO' in form or 'FIXME' in form: raise SystemExit('bounds range TODO/FIXME remains')
if sys.argv[2]:
    form=form.replace('%fixnum-<-unsigned', '%fixnum-<', 1)
for anchor in ('(let ((size (%object-header-data object)))',
               '(not (mezzano.runtime::%fixnum-< size range))',
               'mezzano.runtime::%fixnum-<-unsigned'):
    if anchor not in form: raise SystemExit(f'missing bounds anchor: {anchor}')
# Pure model: guarded upper bound rejects underflow and unsigned compare rejects negatives.
def valid(slot,size,rng):
    return size >= rng and 0 <= slot < size-rng
for slot,size,rng,expected in ((0,10,2,True), (7,10,2,True), (8,10,2,False), (-1,10,2,False), (0,3,5,False)):
    if valid(slot,size,rng) != expected: raise SystemExit('bounds model failed')
print('runtime unsigned range bounds contract passed')
PY
if [[ -z "$mutation" ]]; then
  if RUNTIME_MUTATION_RUN=1 bash "$0" >/dev/null 2>&1; then
    echo 'runtime bounds mutation unexpectedly survived' >&2; exit 1
  fi
  echo 'runtime bounds mutation rejected'
fi
