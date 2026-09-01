#!/usr/bin/env bash
# Contract for without-footholds conditional slot update.
set -euo pipefail
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/../.." && pwd)
source_file=${THREAD_SOURCE:-"$repo_root/supervisor/thread.lisp"}
mutation=${THREAD_MUTATION_RUN:-}
python3 - "$source_file" "$mutation" <<'PY'
from pathlib import Path
import sys
s=Path(sys.argv[1]).read_text(); start=s.index('(defmacro without-footholds'); end=s.index('\n(defmacro with-footholds',start); form=s[start:end]
if 'TODO: Restructure this' in form or 'FIXME' in form: raise SystemExit('without-footholds marker remains')
if sys.argv[2]: form=form.replace('(when ,old-allow-with-footholds', '(progn')
for a in ('(when ,old-allow-with-footholds','thread-allow-with-footholds', 'Avoid touching the allow-with-footholds slot unless it is'):
    if a not in form: raise SystemExit(f'missing foothold fast-path anchor: {a}')
# Executable state model: disabled path leaves slot untouched; enabled restores it.
def model(old):
    writes=[]; current=old
    if old:
        current=False; writes.append(False)
    current=old
    if old: writes.append(True)
    return current,writes
if model(False)!=(False,[]) or model(True)!=(True,[False,True]): raise SystemExit('foothold model failed')
print('without-footholds conditional update contract passed')
PY
if [[ -z "$mutation" ]]; then
 if THREAD_MUTATION_RUN=1 bash "$0" >/dev/null 2>&1; then echo 'foothold mutation unexpectedly survived' >&2; exit 1; fi
 echo 'foothold mutation rejected'
fi
