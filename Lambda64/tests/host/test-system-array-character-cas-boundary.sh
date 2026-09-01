#!/usr/bin/env bash
# Contract for the character-array CAS atomicity boundary.
set -euo pipefail
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/../.." && pwd)
source_file=${ARRAY_SOURCE:-"$repo_root/system/array.lisp"}
mutation=${ARRAY_MUTATION_RUN:-}
python3 - "$source_file" "$mutation" <<'PY'
from pathlib import Path
import sys
s=Path(sys.argv[1]).read_text(); start=s.index('(defun (cas %row-major-aref)'); end=s.index('\n(defun row-major-aref',start); form=s[start:end]
if 'TODO' in form or 'FIXME' in form: raise SystemExit('character CAS marker remains')
if sys.argv[2]: form=form.replace('backing storage may widen','backing storage is fixed',1)
for a in ('(character-array-p array)','(error "CAS not supported on character arrays (backing storage may widen)")'):
    if a not in form: raise SystemExit(f'missing character CAS boundary: {a}')
print('character-array CAS atomicity boundary passed')
PY
if [[ -z "$mutation" ]]; then
 if ARRAY_MUTATION_RUN=1 bash "$0" >/dev/null 2>&1; then echo 'array CAS mutation unexpectedly survived' >&2; exit 1; fi
 echo 'array CAS mutation rejected'
fi
