#!/usr/bin/env bash
set -euo pipefail
script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "$script_dir/../.." && pwd)
source_file=${FAST_CLASS_HASH_SOURCE:-"$repo_root/system/clos/fast-class-hash-table.lisp"}
python3 - "$source_file" "${FAST_CLASS_HASH_PAIR_MUTATION_RUN:-}" <<'PY'
from pathlib import Path
import sys
source = Path(sys.argv[1]).read_text(encoding='utf-8')
start = source.index('(defun fast-class-hash-table-entry-known-hash')
end = source.index('\n(defun fast-class-hash-table-entry ', start)
form = source[start:end]
if sys.argv[2]:
    form = form.replace('(mezzano.extensions:weak-pointer-pair storage)', '(values nil nil nil)', 1)
required = ['(mezzano.extensions:weak-pointer-pair storage)',
            '(multiple-value-bind (key value livep)',
            '(and livep (eq class key) value)']
missing = [x for x in required if x not in form]
if 'TODO: Replace with WEAK-POINTER-PAIR' in form:
    missing.append('TODO marker removal')
if missing:
    raise SystemExit('fast-class-hash weak-pair contract missing: ' + ', '.join(missing))
print('fast-class-hash weak-pair contract passed')
PY
if [[ -z "${FAST_CLASS_HASH_PAIR_MUTATION_RUN:-}" ]]; then
  if FAST_CLASS_HASH_PAIR_MUTATION_RUN=1 bash "$0" >/dev/null 2>&1; then
    echo 'fast-class-hash weak-pair mutation unexpectedly survived' >&2
    exit 1
  fi
  echo 'fast-class-hash weak-pair mutation rejected'
fi
