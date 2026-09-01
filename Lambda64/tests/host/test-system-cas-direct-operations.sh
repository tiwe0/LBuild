#!/usr/bin/env bash
# Regression coverage for direct atomic RMW dispatch before CAS fallback.
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "$script_dir/../.." && pwd)
source_file=${CAS_SOURCE:-"$repo_root/system/cas.lisp"}

python3 - "$source_file" "${CAS_DIRECT_OPERATIONS_MUTATION_RUN:-}" <<'PY'
from pathlib import Path
import sys
source = Path(sys.argv[1]).read_text(encoding='utf-8')
marker = '(defmacro define-atomic-rmw-operation'
start = source.index(marker)
depth = 0
in_string = in_comment = escaped = False
for i in range(start, len(source)):
    c = source[i]
    if in_comment:
        if c == '\n': in_comment = False
        continue
    if in_string:
        if escaped: escaped = False
        elif c == '\\': escaped = True
        elif c == '"': in_string = False
        continue
    if c == ';': in_comment = True
    elif c == '"': in_string = True
    elif c == '(': depth += 1
    elif c == ')':
        depth -= 1
        if depth == 0:
            form = source[start:i + 1]
            break
else:
    raise SystemExit('unterminated atomic RMW macro')
if sys.argv[2]:
    form = form.replace("',symbol-function", "'missing-direct-operation", 1)
required = [
    "',symbol-function",
    "',struct-slot-function",
    'Fall back on a CAS loop',
    'cons-operations',
]
missing = [token for token in required if token not in form]
if missing:
    raise SystemExit('atomic RMW direct-dispatch contract missing: ' + ', '.join(missing))
print('atomic RMW direct-dispatch contract passed')
PY

if [[ -z "${CAS_DIRECT_OPERATIONS_MUTATION_RUN:-}" ]]; then
  if CAS_DIRECT_OPERATIONS_MUTATION_RUN=1 bash "$0" >/dev/null 2>&1; then
    echo "atomic RMW direct-dispatch mutation unexpectedly survived" >&2
    exit 1
  fi
  echo "atomic RMW direct-dispatch mutation rejected"
fi
