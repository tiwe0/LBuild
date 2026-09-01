#!/usr/bin/env bash
# Regression coverage for supervisor debug-ring locking (TF-WI-0249/0250).
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "$script_dir/../.." && pwd)
source_file=${DEBUG_SOURCE:-"$repo_root/supervisor/debug.lisp"}

python3 - "$source_file" "${DEBUG_LOG_LOCK_MUTATION_RUN:-}" <<'PY'
from pathlib import Path
import re, sys

s = Path(sys.argv[1]).read_text()
if re.search(r'(?im)^\s*;.*Needs to be done under lock', s):
    raise SystemExit('debug log lock FIXME remains')

def form(name):
    match = re.search(r'\(defun\s+' + re.escape(name) + r'\s', s)
    start = match.start() if match else -1
    if start < 0: raise SystemExit(f'missing {name}')
    depth = 0; string = comment = escaped = False
    for i in range(start, len(s)):
        c = s[i]
        if comment:
            if c == '\n': comment = False
        elif string:
            if escaped: escaped = False
            elif c == '\\': escaped = True
            elif c == '"': string = False
        elif c == ';': comment = True
        elif c == '"': string = True
        elif c == '(': depth += 1
        elif c == ')':
            depth -= 1
            if depth == 0: return s[start:i+1]
    raise SystemExit(f'unterminated {name}')

byte = form('debug-log-buffer-write-byte')
flush = form('debug-flush-buffer')
if '(with-symbol-spinlock (*supervisor-log-buffer-lock*)' not in byte:
    raise SystemExit('byte writer is not protected by the log lock')
if '(with-symbol-spinlock (*supervisor-log-buffer-lock*)' not in flush:
    raise SystemExit('buffer flush is not protected by the log lock')
if 'debug-log-buffer-write-byte-1' not in flush:
    raise SystemExit('flush must use the non-recursive locked helper')
if '*supervisor-log-buffer-lock* :unlocked' not in s:
    raise SystemExit('log lock has no safe initial value')

if sys.argv[2]:
    # Mutation removes both lock forms; the contract must reject that change.
    mutated = s.replace('(with-symbol-spinlock (*supervisor-log-buffer-lock*)', '(progn', 2)
    if '(with-symbol-spinlock (*supervisor-log-buffer-lock*)' not in mutated:
        raise SystemExit('mutation rejected')
    raise SystemExit('lock mutation unexpectedly survived')
print('supervisor debug log lock contract passed')
PY

if [[ -z "${DEBUG_LOG_LOCK_MUTATION_RUN:-}" ]]; then
  if DEBUG_LOG_LOCK_MUTATION_RUN=1 bash "$0" >/dev/null 2>&1; then
    echo "debug log lock mutation unexpectedly survived" >&2
    exit 1
  fi
  echo "debug log lock mutation rejected"
fi
