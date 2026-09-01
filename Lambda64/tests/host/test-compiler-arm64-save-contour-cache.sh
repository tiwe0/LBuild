#!/usr/bin/env bash
set -euo pipefail
repo_root=$(cd "$(dirname "$0")/../.." && pwd)
source="$repo_root/compiler/backend/arm64/codegen.lisp"
python3 - "$source" <<'PY'
from pathlib import Path
import sys
text = Path(sys.argv[1]).read_text()
assert 'FIXME: Don\'t recompute contours for each save instruction.' not in text
for token in ('Dynamic contours are immutable for a backend function',
              'Compute them once',
              '(gethash backend-function *prepass-data*)',
              '(ir::dynamic-contours backend-function)'):
    assert token in text, token
# Ensure the cache lookup guards the dynamic-contours call.
start = text.index('defmethod lap-prepass (backend-function (instruction ir:save-multiple-instruction)')
body = text[start:text.index('(defmethod emit-lap', start)]
assert body.index('(or (gethash backend-function *prepass-data*)') < body.index('(ir::dynamic-contours backend-function)')
PY
printf 'ARM64 save-multiple contour cache checks passed\n'
