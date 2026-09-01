#!/usr/bin/env bash
# Regression coverage for method-combination lookup dispatch target.
set -euo pipefail
script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "$script_dir/../.." && pwd)
source_file=${METHOD_COMBINATION_SOURCE:-"$repo_root/system/clos/method-combination.lisp"}
python3 - "$source_file" "${METHOD_COMBINATION_MUTATION_RUN:-}" <<'PY'
from pathlib import Path
import sys
s=Path(sys.argv[1]).read_text(encoding='utf-8')
start=s.index('(defun resolve-method-combination')
end=s.index('\n\n',start)
form=s[start:end]
if sys.argv[2]: form=form.replace('(class-prototype (find-class \'standard-generic-function))', '#\'class-name')
for token in ["(class-prototype (find-class 'standard-generic-function))", "(find-method-combination"]:
    if token not in form: raise SystemExit('method-combination resolution contract missing: '+token)
if "#'class-name" in form: raise SystemExit('unrelated CLASS-NAME generic function still used')
print('method-combination resolution contract passed')
PY
if [[ -z "${METHOD_COMBINATION_MUTATION_RUN:-}" ]]; then
  if METHOD_COMBINATION_MUTATION_RUN=1 bash "$0" >/dev/null 2>&1; then
    echo 'method-combination resolution mutation unexpectedly survived' >&2; exit 1
  fi
  echo 'method-combination resolution mutation rejected'
fi
