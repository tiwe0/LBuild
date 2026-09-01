#!/usr/bin/env bash
set -euo pipefail
repo_root=$(cd "$(dirname "$0")/../.." && pwd)
source="$repo_root/compiler/backend/arm64/memory.lisp"
python3 - "$source" <<'PY'
from pathlib import Path
import sys
text = Path(sys.argv[1]).read_text()
assert '(sys.int::cas sys.int::%memref-t)' in text
assert '(sys.int::dcas sys.int::%memref-t)' in text
for token in ('arm64-cas-mem-instruction', ':opcode \'lap:casal',
              ':old-value old', ':new-value new', ':current-value current-value',
              'arm64-dcas-mem-instruction', 'CASL instructions'):
    assert token in text, token
PY
printf 'ARM64 memref CAS implementation/DCAS boundary checks passed\n'
