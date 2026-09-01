#!/usr/bin/env bash
set -euo pipefail
repo_root=$(cd "$(dirname "$0")/../.." && pwd)
source="$repo_root/compiler/backend/arm64/memory.lisp"
spec="$repo_root/../docs/modernization/todo-fixme/specs/TF-WI-0017.md"
python3 - "$source" "$spec" <<'PY'
from pathlib import Path
import sys
source = Path(sys.argv[1]).read_text()
spec = Path(sys.argv[2]).read_text()
assert 'TODO: dcas memref-t.' in source
for token in ('128-bit memref CAS lowering', 'raw effective addresses',
              'memory-order contract'):
    assert token in source, token
for token in ('casp[a][l]', '128-bit\ncompare-exchange IR instruction',
              'arbitrary address', '16-byte alignment', 'misaligned'):
    assert token in spec, token
PY
printf 'ARM64 memref DCAS boundary checks passed\n'
