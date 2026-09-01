#!/usr/bin/env bash
# Regression coverage for direct atomic RMW operations on fixnum struct slots.
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "$script_dir/../.." && pwd)
source_file=${CAS_SOURCE:-"$repo_root/system/cas.lisp"}

python3 - "$source_file" "${CAS_STRUCT_SLOT_MUTATION_RUN:-}" <<'PY'
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
    elif c == '(' : depth += 1
    elif c == ')':
        depth -= 1
        if depth == 0:
            form = source[start:i + 1]
            break
else:
    raise SystemExit('unterminated atomic RMW macro')

# The struct accessor branch is the direct path used by declared-fixnum slots;
# only unknown places should reach the CAS loop fallback.
required = [
    'struct-accessor-info',
    "',struct-slot-function",
    'Fall back on a CAS loop for places without a direct operation.',
]
missing = [token for token in required if token not in form]
# The concrete fixnum operations must be wired to struct-slot primitives.
for token in ('%atomic-fixnum-add-struct-slot', ':require-fixnum t'):
    if token not in source:
        missing.append(token)
if missing:
    raise SystemExit('struct-slot direct CAS contract missing: ' + ', '.join(missing))
if 'TODO: Support directly on struct slots' in form:
    raise SystemExit('struct-slot CAS TODO remains unresolved')
if sys.argv[2]:
    # Mutation-negative: deleting the direct struct operation must be detected.
    form = form.replace("',struct-slot-function", "'missing-struct-operation", 1)
    if "',struct-slot-function" in form:
        raise SystemExit('mutation did not remove direct struct operation')
    raise SystemExit('mutated struct-slot direct CAS contract rejected')
print('struct-slot direct CAS contract passed')
PY

if [[ -z "${CAS_STRUCT_SLOT_MUTATION_RUN:-}" ]]; then
  if CAS_STRUCT_SLOT_MUTATION_RUN=1 bash "$0" >/dev/null 2>&1; then
    echo "struct-slot direct CAS mutation unexpectedly survived" >&2
    exit 1
  fi
  echo "struct-slot direct CAS mutation rejected"
fi
