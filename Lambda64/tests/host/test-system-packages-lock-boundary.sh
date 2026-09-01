#!/usr/bin/env bash
# Contract for package-system lock ownership and nested-call elision.
set -euo pipefail
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/../.." && pwd)
source_file=${PACKAGES_SOURCE:-"$repo_root/system/packages.lisp"}
mutation=${PACKAGES_MUTATION_RUN:-}
python3 - "$source_file" "$mutation" <<'PY'
from pathlib import Path
import sys
s=Path(sys.argv[1]).read_text(); start=s.index('(defun call-with-package-system-lock'); end=s.index('\n(defmacro with-package-system-lock',start); form=s[start:end]
if 'FIXME' in s[start-300:start] or 'recursive mutex' in s[start-300:start]: raise SystemExit('recursive mutex marker remains')
if sys.argv[2]: form=form.replace('mezzano.supervisor:mutex-held-p *package-system-lock*','(constantly nil)')
for a in ('mezzano.supervisor:mutex-held-p *package-system-lock*','(funcall thunk)','(mezzano.supervisor:with-mutex (*package-system-lock*)'):
    if a not in form: raise SystemExit(f'missing package lock anchor: {a}')
print('package-system lock ownership contract passed')
PY
if [[ -z "$mutation" ]]; then
 if PACKAGES_MUTATION_RUN=1 bash "$0" >/dev/null 2>&1; then echo 'package lock mutation unexpectedly survived' >&2; exit 1; fi
 echo 'package lock mutation rejected'
fi
