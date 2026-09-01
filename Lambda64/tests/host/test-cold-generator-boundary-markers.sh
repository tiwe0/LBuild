#!/usr/bin/env bash
set -euo pipefail
repo_root=$(cd "$(dirname "$0")/../.." && pwd)
python3 - "$repo_root" <<'PY'
from pathlib import Path
import sys
root = Path(sys.argv[1])
cold = (root / 'tools/cold-generator2/cold-generator.lisp').read_text()
x86 = (root / 'tools/cold-generator2/x86-64.lisp').read_text()
classes = (root / 'tools/cold-generator2/class-definitions.lisp').read_text()
clos = (root / 'tools/cold-generator2/clos.lisp').read_text()
environment = (root / 'tools/cold-generator2/environment.lisp').read_text()
serialize = (root / 'tools/cold-generator2/serialize.lisp').read_text()
assert '("supervisor/arm64/cpu.lisp" :arm64)' in cold
assert 'TODO: Turn this into a direct named call.' in x86
assert 'FIXME: Source locations for these are lost.' in classes
assert "FIXME: This doesn't quite work with large bytes." in classes
assert 'FIXME: Need to include an initfunction' in clos
assert 'FIXME: Should be weak, but how to deal with complex keys?' in environment
assert ':test' in environment and ':weakness :key' in environment
assert 'drain-initialization-queue' in serialize
for ident in ('0436', '0437', '0440', '0441', '0443', '0448', '0454'):
    spec = (root.parent / 'docs/modernization/todo-fixme/specs' / f'TF-WI-{ident}.md').read_text()
    for token in ('status: active', 'owner: runtime', 'review-cycle: 30d', f'TF-WI-{ident}'):
        assert token in spec, (ident, token)
print('cold-generator boundary markers passed')
PY
