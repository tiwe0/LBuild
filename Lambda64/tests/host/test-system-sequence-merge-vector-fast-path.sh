#!/usr/bin/env bash
# Regression coverage for MERGE avoiding redundant vector copies.
set -euo pipefail
script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "$script_dir/../.." && pwd)
source_file=${SEQUENCE_SOURCE:-"$repo_root/system/sequence.lisp"}
python3 - "$source_file" "${SEQUENCE_MERGE_VECTOR_MUTATION_RUN:-}" <<'PY'
from pathlib import Path
import sys
source = Path(sys.argv[1]).read_text(encoding='utf-8')
start = source.index('(defun merge (result-type sequence1 sequence2 predicate')
end = source.index('\n\n(defun map-into', start)
form = source[start:end]
required = [
    "(if (vectorp sequence1)",
    "(if (vectorp sequence2)",
    "(coerce sequence1 'vector)",
    "(coerce sequence2 'vector)",
]
missing = [token for token in required if token not in form]
if missing:
    raise SystemExit('MERGE vector fast path missing: ' + ', '.join(missing))
if sys.argv[2]:
    form = form.replace("(if (vectorp sequence1)\n                           sequence1\n                           (coerce sequence1 'vector))", "(coerce sequence1 'vector)", 1)
    form = form.replace("(if (vectorp sequence2)\n                           sequence2\n                           (coerce sequence2 'vector))", "(coerce sequence2 'vector)", 1)
    if '(if (vectorp sequence1)' not in form or '(if (vectorp sequence2)' not in form:
        raise SystemExit('vector fast-path mutation survived')
print('MERGE vector fast-path contract passed')
PY
if [[ -z "${SEQUENCE_MERGE_VECTOR_MUTATION_RUN:-}" ]]; then
  if SEQUENCE_MERGE_VECTOR_MUTATION_RUN=1 bash "$0" >/dev/null 2>&1; then
    echo 'MERGE vector fast-path mutation unexpectedly survived' >&2
    exit 1
  fi
  echo 'MERGE vector fast-path mutation rejected'
fi
