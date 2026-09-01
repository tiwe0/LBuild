#!/usr/bin/env bash
# Regression contract for disk driver transfer-limit enforcement.
set -euo pipefail

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/../.." && pwd)
source_file=${DISK_SOURCE:-"$repo_root/supervisor/disk.lisp"}
mutation=${DISK_TRANSFER_LIMIT_MUTATION_RUN:-}

python3 - "$source_file" "$mutation" <<'PY'
from pathlib import Path
import sys

source = Path(sys.argv[1]).read_text(encoding="utf-8")
if sys.argv[2]:
    # Mutation removes the guard body; the contract must then fail closed.
    source = source.replace('(> (disk-request-n-sectors request) max-transfer)',
                            '(> (disk-request-n-sectors request) 0)', 1)

def form_at(marker):
    start = source.index(marker)
    depth = 0
    string = comment = escaped = False
    for i in range(start, len(source)):
        c = source[i]
        if comment:
            if c == '\n': comment = False
            continue
        if string:
            if escaped: escaped = False
            elif c == '\\': escaped = True
            elif c == '"': string = False
            continue
        if c == ';': comment = True
        elif c == '"': string = True
        elif c == '(' : depth += 1
        elif c == ')' :
            depth -= 1
            if depth == 0: return source[start:i+1]
    raise SystemExit("unterminated form")

form = form_at('(defun process-one-disk-request')
required = [
    '(disk-max-transfer disk)',
    '(> (disk-request-n-sectors request) max-transfer)',
    'Disk request exceeds device transfer limit.',
    '(unwind-protect',
    'release-physical-pages bounce-buffer',
]
missing = [item for item in required if item not in form]
if missing:
    raise SystemExit("disk transfer-limit contract missing: " + ", ".join(missing))
print("disk transfer-limit contract passed")
PY

if [[ -n "$mutation" ]]; then
  echo "mutation unexpectedly passed" >&2
  exit 1
fi
