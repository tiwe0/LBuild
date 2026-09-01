#!/usr/bin/env bash
# Contract for isolating finalizer errors in the GC worker.
set -euo pipefail
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/../.." && pwd)
source_file=${GC_SOURCE:-"$repo_root/system/gc.lisp"}
mutation=${GC_MUTATION_RUN:-}
python3 - "$source_file" "$mutation" <<'PY'
from pathlib import Path
import sys
s=Path(sys.argv[1]).read_text(); start=s.index('(defun run-finalizers ()'); end=s.index('\n(defun fixup-tlabs',start); form=s[start:end]
if 'TODO' in s[start-300:start+100] or 'FIXME' in form: raise SystemExit('GC finalizer marker remains')
if sys.argv[2]: form=form.replace('(ignore-errors', '(progn',1)
for a in ('(handler-case','(condition (condition)','(ignore-errors\n                    (mezzano.supervisor:debug-print-line','(unwind-protect'):
    if a not in form: raise SystemExit(f'missing finalizer isolation anchor: {a}')
if form.index('(unwind-protect') > form.index('(handler-case'):
    raise SystemExit('finalizer must be protected before handler execution')
print('GC finalizer error isolation contract passed')
PY
if [[ -z "$mutation" ]]; then
 if GC_MUTATION_RUN=1 bash "$0" >/dev/null 2>&1; then echo 'GC finalizer mutation unexpectedly survived' >&2; exit 1; fi
 echo 'GC finalizer mutation rejected'
fi
