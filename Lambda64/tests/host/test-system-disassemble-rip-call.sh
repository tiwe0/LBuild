#!/usr/bin/env bash
# Regression coverage for direct relative versus indirect RIP-relative calls.
set -euo pipefail
script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "$script_dir/../.." && pwd)
source_file=${DISASSEMBLE_SOURCE:-"$repo_root/system/disassemble-x86-64.lisp"}
python3 - "$source_file" "${RIP_CALL_MUTATION_RUN:-}" <<'PY'
from pathlib import Path
import sys
source = Path(sys.argv[1]).read_text(encoding='utf-8')
class_start = source.index('(defclass x86-64-instruction')
class_end = source.index('\n\n(defun make-instruction', class_start)
class_def = source[class_start:class_end]
decode_start = source.index('(defun decode-jz')
decode_end = source.index('\n\n(defun decode-group-1a', decode_start)
decoder = source[decode_start:decode_end]
print_start = source.index('(defmethod dis:print-instruction')
print_end = source.index('\n(defun decode-seg', print_start)
printer = source[print_start:print_end]
if sys.argv[2]:
    # Simulate the bug: remove the direct-target guard, so E8 is treated as an indirect memory call.
    printer = printer.replace('(not (inst-direct-rip-target-p instruction))', 't')
required = [
    ':reader inst-direct-rip-target-p',
    '(setf (slot-value instruction \'%direct-rip-target-p) t)',
    '(not (inst-direct-rip-target-p instruction))',
]
missing = [token for token in required if token not in class_def + decoder + printer]
if missing:
    raise SystemExit('RIP call annotation contract missing: ' + ', '.join(missing))
if 'TODO: Differentiate between direct calls' in printer:
    raise SystemExit('RIP call annotation TODO remains')
print('RIP direct/indirect call annotation contract passed')
PY
if [[ -z "${RIP_CALL_MUTATION_RUN:-}" ]]; then
  if RIP_CALL_MUTATION_RUN=1 bash "$0" >/dev/null 2>&1; then
    echo 'RIP call annotation mutation unexpectedly survived' >&2; exit 1
  fi
  echo 'RIP call annotation mutation rejected'
fi
