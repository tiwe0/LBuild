#!/usr/bin/env bash
# Host contract for funcallable-instance-function mutation and entry routing.
set -euo pipefail
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/../.." && pwd)
source_file=${FUNCTION_SOURCE:-"$repo_root/runtime/function.lisp"}
mutation=${FUNCTION_MUTATION_RUN:-}
python3 - "$source_file" "$mutation" <<'PY'
from pathlib import Path
import re, sys
s=Path(sys.argv[1]).read_text()
if re.search(r'(?i)todo|fixme', s[s.index('(defun (setf funcallable-instance-function)'):s.index('(defun compiled-function-p')]):
    raise SystemExit('funcallable-instance-function setter still contains TODO/FIXME')
start=s.index('(defun (setf funcallable-instance-function)')
end=s.index('\n(defun compiled-function-p', start)
form=s[start:end]
if sys.argv[2]:
    form=form.replace('(funcallable-instance-entry-point value)', 'sys.int::*funcallable-instance-trampoline*', 1)
required=[
 '(check-type value function)',
 '(%type-check funcallable-instance +object-tag-funcallable-instance+',
 '(%object-ref-unsigned-byte-64',
 '(funcallable-instance-entry-point value)',
 '(%object-ref-t funcallable-instance +funcallable-instance-function+)',
]
for anchor in required:
    if anchor not in form: raise SystemExit(f'missing setter contract: {anchor}')
# Ensure entry is written before boxed target, matching allocation publication order.
entry=form.index('(%object-ref-unsigned-byte-64')
boxed=form.index('(%object-ref-t funcallable-instance +funcallable-instance-function+)')
if entry > boxed: raise SystemExit('entry point must be published before boxed target')
# Deterministic host model of both tag branches and mutation publication.
entry_for=lambda tag: 111 if tag == 60 else 222
for tag, expected in ((60,111),(55,222),(61,222)):
    if entry_for(tag) != expected: raise SystemExit('entry routing model failed')
print('runtime function setter contract passed (mutation-aware)')
PY
if [[ -z "$mutation" ]]; then
  if FUNCTION_MUTATION_RUN=1 bash "$0" >/dev/null 2>&1; then
    echo 'funcallable-instance-function mutation unexpectedly survived' >&2
    exit 1
  fi
  echo 'funcallable-instance-function mutation rejected'
fi
