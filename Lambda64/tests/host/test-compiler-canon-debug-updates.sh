#!/usr/bin/env bash
set -euo pipefail
repo_root=$(cd "$(dirname "$0")/../.." && pwd)
source="$repo_root/compiler/backend/canon.lisp"
python3 - "$source" <<'PY'
from pathlib import Path
import sys
text = Path(sys.argv[1]).read_text()
assert 'TODO: Insert debug variable updates where needed.' not in text
for token in ('build-debug-variable-value-map',
              'debug-update-variable-instruction',
              ':variable (first entry)',
              ':value result',
              ':representation (third entry)'):
    assert token in text, token
# The update must be inserted after the ABI move, not before the call result exists.
assert text.index('(ir:insert-after\n                             backend-function inst') < text.index('debug-update-variable-instruction')
PY
printf 'canonical call debug-update checks passed\n'