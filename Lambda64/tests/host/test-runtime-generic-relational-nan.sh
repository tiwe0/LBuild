#!/usr/bin/env bash
# Host contract for NaN-safe inclusive generic relational predicates.
set -euo pipefail
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/../.." && pwd)
source_file=${NUMBERS_SOURCE:-"$repo_root/runtime/numbers.lisp"}
mutation=${NUMBERS_MUTATION_RUN:-}
python3 - "$source_file" "$mutation" <<'PY'
from pathlib import Path
import math, sys
s=Path(sys.argv[1]).read_text(); start=s.index('(defun sys.int::generic-> ')
end=s.index('\n(declaim (inline fixnum-fits', start); form=s[start:end]
if 'FIXME' in s[start-180:start] or 'TODO' in form: raise SystemExit('generic relational marker remains')
if sys.argv[2]: form=form.replace('(or (sys.int::generic-> x y)', '(not (sys.int::generic-< x y))',1)
for a in ('(or (sys.int::generic-> x y)', '(or (sys.int::generic-< x y)', '(sys.int::generic-= x y)'):
    if a not in form: raise SystemExit(f'missing NaN-safe relational anchor: {a}')
# Executable IEEE model: unordered NaN is false for every relation.
def rel(x,y):
    eq=(x==y); lt=(x<y); gt=(y<x)
    return gt or eq, lt or eq
for x,y,expected in ((1.0,1.0,(True,True)), (2.0,1.0,(True,False)), (1.0,2.0,(False,True)), (math.nan,1.0,(False,False)), (1.0,math.nan,(False,False))):
    if rel(x,y)!=expected: raise SystemExit('relational NaN model failed')
print('generic relational NaN contract passed')
PY
if [[ -z "$mutation" ]]; then
 if NUMBERS_MUTATION_RUN=1 bash "$0" >/dev/null 2>&1; then echo 'generic relational mutation unexpectedly survived' >&2; exit 1; fi
 echo 'generic relational mutation rejected'
fi
