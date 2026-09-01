#!/usr/bin/env bash
# Focused regression coverage for LIST-CALLEES function designators.
set -euo pipefail
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/../.." && pwd)
source_file=${DEBUG_SOURCE:-"$repo_root/system/debug.lisp"}
python3 - "$source_file" "${DEBUG_MUTATION_RUN:-}" <<'PY'
from pathlib import Path
import sys
s = Path(sys.argv[1]).read_text(encoding='utf-8')
required = [
    '(defun list-callees (function-designator)',
    '(if (functionp function-designator)',
    'function-designator\n                 (fdefinition function-designator)',
]
if sys.argv[2]:
    s = s.replace('(let* ((fn (if (functionp function-designator)\n                 function-designator\n                 (fdefinition function-designator)))',
                  '(let* ((fn (fdefinition function-designator))', 1)
missing = [token for token in required if token not in s]
if missing:
    raise SystemExit('LIST-CALLEES function-designator contract missing: ' + ', '.join(missing))
if '(let* ((fn (fdefinition function-designator))' in s:
    raise SystemExit('LIST-CALLEES function-object path mutation unexpectedly survived')
print('LIST-CALLEES function-designator contract passed')
PY
if [[ -z "${DEBUG_MUTATION_RUN:-}" ]]; then
  if DEBUG_MUTATION_RUN=1 bash "$0" >/dev/null 2>&1; then
    echo 'LIST-CALLEES function-designator mutation unexpectedly survived' >&2
    exit 1
  fi
  echo 'LIST-CALLEES function-designator mutation rejected'
fi
