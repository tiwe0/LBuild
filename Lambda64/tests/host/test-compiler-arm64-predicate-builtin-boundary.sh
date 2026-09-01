#!/usr/bin/env bash
set -euo pipefail
script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "$script_dir/../.." && pwd)
source_file=${ARM64_BUILTIN_SOURCE:-"$repo_root/compiler/backend/arm64/builtin.lisp"}
python3 - "$source_file" "${ARM64_PREDICATE_BUILTIN_MUTATION_RUN:-}" <<'PY'
from pathlib import Path
import sys
s=Path(sys.argv[1]).read_text()
if sys.argv[2]:
    s=s.replace('(eql (length (builtin-result-list builtin)) 1)',
                '(plusp (length (builtin-result-list builtin)))', 1)
required=[
    '(defun lower-predicate-builtin (backend-function inst uses defs)',
    '(consumed-by-p inst next-inst uses defs)',
    '(eql (length (builtin-result-list builtin)) 1)',
    '(keywordp (first (builtin-result-list builtin)))',
]
missing=[x for x in required if x not in s]
if missing: raise SystemExit('ARM64 predicate builtin boundary missing: '+', '.join(missing))
if 'FIXME: This should work when the result consumed by' not in s:
    raise SystemExit('ARM64 predicate builtin FIXME marker unexpectedly removed without implementation evidence')
print('ARM64 predicate builtin boundary passed')
PY
if [[ -z "${ARM64_PREDICATE_BUILTIN_MUTATION_RUN:-}" ]]; then
  if ARM64_PREDICATE_BUILTIN_MUTATION_RUN=1 bash "$0" >/dev/null 2>&1; then
    echo 'ARM64 predicate builtin guard mutation unexpectedly survived' >&2
    exit 1
  fi
  echo 'ARM64 predicate builtin guard mutation rejected'
fi
