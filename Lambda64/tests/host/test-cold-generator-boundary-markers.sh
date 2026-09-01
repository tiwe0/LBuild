#!/usr/bin/env bash
set -euo pipefail
repo_root=$(cd "$(dirname "$0")/../.." && pwd)
python3 - "$repo_root" <<'PY'
from pathlib import Path
import sys
root = Path(sys.argv[1])
cold = (root / 'tools/cold-generator2/cold-generator.lisp').read_text()
x86 = (root / 'tools/cold-generator2/x86-64.lisp').read_text()
assert '("supervisor/arm64/cpu.lisp" :arm64)' in cold
assert 'TODO: Turn this into a direct named call.' in x86
for ident in ('0441', '0454'):
    spec = (root.parent / 'docs/modernization/todo-fixme/specs' / f'TF-WI-{ident}.md').read_text()
    for token in ('status: active', 'owner: runtime', 'review-cycle: 30d', f'TF-WI-{ident}'):
        assert token in spec, (ident, token)
print('cold-generator boundary markers passed')
PY
