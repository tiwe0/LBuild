#!/usr/bin/env bash
# Contract for the allocation profiler's intentionally distinct raw format.
set -euo pipefail
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/../.." && pwd)
source_file=${PROFILER_SOURCE:-"$repo_root/system/profiler.lisp"}
mutation=${PROFILER_MUTATION_RUN:-}
python3 - "$source_file" "$mutation" <<'PY'
from pathlib import Path
import sys
s=Path(sys.argv[1]).read_text(); start=s.index('(defun call-with-allocation-profiling'); end=s.index('\n(defun save-profile',start); form=s[start:end]
if 'TODO' in form or 'FIXME' in form: raise SystemExit('allocation profiler marker remains')
if sys.argv[2]: form=form.replace('compact nested triple vector','normal profile-data',1)
for a in ('make-array 3 :adjustable t :fill-pointer 0','compact nested triple vector','GENERATE-ALLOCATION-FLAME-GRAPH','raw-buffer))'):
    if a not in form: raise SystemExit(f'missing allocation format contract: {a}')
# Executable shape model: triples recursively encode function, bytes, children.
profile=['root', 12, ['leaf', 4, []]]
if len(profile)!=3 or profile[2][1] != 4: raise SystemExit('allocation triple model failed')
print('allocation profiler raw format contract passed')
PY
if [[ -z "$mutation" ]]; then
 if PROFILER_MUTATION_RUN=1 bash "$0" >/dev/null 2>&1; then echo 'profiler format mutation unexpectedly survived' >&2; exit 1; fi
 echo 'profiler format mutation rejected'
fi
