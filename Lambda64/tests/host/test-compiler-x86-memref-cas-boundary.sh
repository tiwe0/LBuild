#!/usr/bin/env bash
set -euo pipefail
repo_root=$(cd "$(dirname "$0")/../.." && pwd)
source="$repo_root/compiler/backend/x86-64/memory.lisp"
python3 - "$source" <<'PY'
from pathlib import Path
import sys

text = Path(sys.argv[1]).read_text()
assert 'TODO: (cas memref-t)' not in text
for token in ('CAS for memref-t remains intentionally unsupported',
              'cmpxchg IR', 'raw', 'effective address',
              'arbitrary address operands', 'memory-order contract'):
    assert token in text, token
PY
printf 'x86 memref CAS boundary checks passed\n'
