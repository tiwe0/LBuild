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
if 'TODO: catch & report errors.' in s[start-300:start+100] or 'FIXME' in form: raise SystemExit('GC finalizer marker remains')
if sys.argv[2]:
    form=form.replace('(ignore-errors', '(progn',1)
    form=form.replace('(unwind-protect', '(progn',1)
for a in ('(handler-case','(condition (condition)','(ignore-errors\n                    (mezzano.supervisor:debug-print-line','(unwind-protect'):
    if a not in form: raise SystemExit(f'missing finalizer isolation anchor: {a}')
if form.index('(unwind-protect') > form.index('(handler-case'):
    raise SystemExit('finalizer must be protected before handler execution')

# Executable miniature of RUN-FINALIZERS: callback failures, report failures,
# and cleanup must all be isolated while later callbacks continue.
class Weak:
    def __init__(self, callback): self.callback = callback
    def clear(self): self.callback = None

def run_finalizers_model(queue, report):
    for weak in queue:
        try:
            try:
                weak.callback()
            except Exception as condition:
                try:
                    report(condition)
                except Exception:
                    pass
        finally:
            weak.clear()

seen=[]
def bad():
    seen.append('bad'); raise RuntimeError('callback')
def good(): seen.append('good')
def broken_report(_): raise RuntimeError('report')
queue=[Weak(bad), Weak(good)]
run_finalizers_model(queue, broken_report)
if seen != ['bad','good'] or any(w.callback is not None for w in queue):
    raise SystemExit('finalizer callback continuation/cleanup model failed')
print('GC finalizer error isolation contract passed')
PY
if [[ -z "$mutation" ]]; then
 if GC_MUTATION_RUN=1 bash "$0" >/dev/null 2>&1; then echo 'GC finalizer mutation unexpectedly survived' >&2; exit 1; fi
 echo 'GC finalizer mutation rejected'
fi
