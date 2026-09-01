#!/usr/bin/env bash
# Focused regression coverage for relevant-argument EMF cache paths.
set -euo pipefail
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/../.." && pwd)
source_file=${EMF_CACHE_SOURCE:-"$repo_root/system/clos/multiple-dispatch-emf-table.lisp"}
python3 - "$source_file" "${EMF_CACHE_MUTATION_RUN:-}" <<'PY'
from pathlib import Path
import sys
s = Path(sys.argv[1]).read_text(encoding='utf-8')
required = [
    '(defun emf-relevant-reordering-table',
    '(bit relevant index)',
    '(setf (emf-cache-top-level cache) value)',
    '(zerop (emf-cache-argument-count cache))',
    '(reordering-table (emf-relevant-reordering-table gf))',
    '(n-args (length reordering-table))',
]
if sys.argv[2]:
    s = s.replace('(n-args (emf-cache-argument-count cache))',
                  '(n-args (length req-args))', 1)
missing = [token for token in required if token not in s]
if missing:
    raise SystemExit('EMF relevance contract missing: ' + ', '.join(missing))
if '(n-args (length req-args))' in s:
    raise SystemExit('EMF cache still walks irrelevant required arguments')
print('multiple-dispatch EMF relevance contract passed')
PY
if [[ -z "${EMF_CACHE_MUTATION_RUN:-}" ]]; then
  if EMF_CACHE_MUTATION_RUN=1 bash "$0" >/dev/null 2>&1; then
    echo 'EMF cache relevance mutation unexpectedly survived' >&2
    exit 1
  fi
  echo 'EMF cache relevance mutation rejected'
fi
