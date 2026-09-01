#!/usr/bin/env bash
set -euo pipefail
script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "$script_dir/../.." && pwd)
source_file=${CLOS_STRUCT_SOURCE:-"$repo_root/system/clos/struct.lisp"}
python3 - "$source_file" "${CLOS_STRUCT_INITARGS_MUTATION_RUN:-}" <<'PY'
from pathlib import Path
import sys
s=Path(sys.argv[1]).read_text(encoding='utf-8')
start=s.index('(defun structure-valid-initargs')
end=s.index('(defmethod make-instance ((class structure-class)', start)
form=s[start:end]
if sys.argv[2]:
    form=form.replace('(applicable-method-initargs (fdefinition (first entry)) (rest entry))','(values nil nil)',1)
required=['(defun structure-valid-initargs','(allocate-instance ,class)','(initialize-instance ,(class-prototype class))','(shared-initialize ,(class-prototype class) t)','(applicable-method-initargs']
missing=[x for x in required if x not in form]
if 'TODO: Permit initargs' in form: missing.append('TODO marker removal')
if missing: raise SystemExit('structure initarg protocol missing: '+', '.join(missing))
print('structure initarg protocol contract passed')
PY
if [[ -z "${CLOS_STRUCT_INITARGS_MUTATION_RUN:-}" ]]; then
  if CLOS_STRUCT_INITARGS_MUTATION_RUN=1 bash "$0" >/dev/null 2>&1; then
    echo 'structure initarg mutation unexpectedly survived' >&2; exit 1
  fi
  echo 'structure initarg mutation rejected'
fi
