#!/usr/bin/env bash
# Host contract for structure-definition layout hash initialization.
set -euo pipefail
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/../.." && pwd)
source_file=${STRUCT_SOURCE:-"$repo_root/runtime/struct.lisp"}
mutation=${STRUCT_MUTATION_RUN:-}
python3 - "$source_file" "$mutation" <<'PY'
from pathlib import Path
import sys
s=Path(sys.argv[1]).read_text()
start=s.index('(defun sys.int::make-struct-definition')
end=s.index('\n(in-package :mezzano.internals)', start)
form=s[start:end]
if 'FIXME' in form or 'TODO' in form: raise SystemExit('struct layout hash marker remains')
if sys.argv[2]: form=form.replace(':hash (sxhash name)', ':hash nil', 1)
for anchor in (':hash (sxhash name)', ':class def', ':obsolete nil'):
    if anchor not in form: raise SystemExit(f'missing layout hash anchor: {anchor}')
if form.index(':hash (sxhash name)') > form.index(':obsolete nil'):
    raise SystemExit('layout hash must be initialized with layout construction')
print('runtime struct layout hash contract passed')
PY
if [[ -z "$mutation" ]]; then
  if STRUCT_MUTATION_RUN=1 bash "$0" >/dev/null 2>&1; then echo 'struct hash mutation unexpectedly survived' >&2; exit 1; fi
  echo 'struct hash mutation rejected'
fi
