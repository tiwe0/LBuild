#!/usr/bin/env bash
set -euo pipefail
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/../.." && pwd)
source_file=${CLOSETTE_SOURCE:-"$repo_root/system/clos/closette.lisp"}
python3 - "$source_file" <<'PY'
from pathlib import Path
import re, sys
s = Path(sys.argv[1]).read_text(encoding='utf-8')

def require(pattern, message):
    if not re.search(pattern, s, re.S):
        raise SystemExit(message)

if re.search(r'(?im)^\s*;+\s*(?:TODO|FIXME)\b', s):
    raise SystemExit('closette.lisp still contains TODO/FIXME markers')
require(r'defun instance-slot-access-function.*funcallable-standard-instance-access', 'slot fast path does not select the instance access protocol')
require(r'update-instance-for-new-layout new-instance instance', 'obsolete forwarding chain does not populate from replacement and supersede original')
require(r'defun layout-instance-slot-pairs.*class-layouts-compatible-p', 'layout compatibility is not pair-order independent')
require(r'defun make-instances-obsolete.*install-class-layout', 'class finalization does not use the obsolescence protocol')
require(r'&key generic-function-class method-class environment', ':environment is not explicitly accepted')
require(r'defun one-effective-eql-table-assoc.*with-mutex.*weak-alist-assoc', 'single-dispatch EQL cache lookup is not locked')
require(r'remaining-methods \(remove around methods :count 1\)', 'around recursion does not retain more-specific primaries')
if re.search(r'cdr\s+\(member\s+around\s+methods', s):
    raise SystemExit('around recursion still truncates methods before the current around method')
require(r'defun standard-call-method-list.*method-fast-function around next-emfun next-methods', 'around next-method list is not filtered and ordered')
require(r'effective-method-required-arguments.*list\*', 'generated effective method does not enforce the required arity')
require(r'not \(standard-generic-function-instance-p gf\)', 'custom generic function does not use compute-effective-method')
require(r'defun ensure-finalized-class-reader.*class-default-initargs', 'finalization-sensitive class readers are not guarded')
require(r'defgeneric class-prototype.*class built-in-class.*slot-boundp', 'built-in prototype is not cached on the class')
require(r'defun initarg-cache-safe-p.*eql-specializer', 'initarg cache does not account for EQL specializers')
require(r'defun flush-generic-functions-specializing-on-class-tree.*safe-class-direct-subclasses', 'indirect specializer invalidation is absent')
print('closette modernization source contracts passed')
PY
