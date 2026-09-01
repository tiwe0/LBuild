#!/usr/bin/env bash
set -euo pipefail
repo_root=$(cd "$(dirname "$0")/../.." && pwd)
source="$repo_root/compiler/backend/arm64/memory.lisp"
python3 - "$source" <<'PY'
from pathlib import Path
import sys
text = Path(sys.argv[1]).read_text()
assert 'TODO: (cas memref-t)' not in text
assert 'TODO: Convert this to use the cas instructions' not in text
for token in ('CAS/DCAS for memref-t remain intentionally unsupported',
              'generic', 'compare-exchange IR', 'raw effective addresses',
              'memory-order contract', '16-byte form for DCAS',
              'Integer memref CAS below', 'SSA-safe', 'arm64-cas-mem-instruction'):
    assert token in text, token
PY
printf 'ARM64 memref CAS/DCAS boundary checks passed\n'
