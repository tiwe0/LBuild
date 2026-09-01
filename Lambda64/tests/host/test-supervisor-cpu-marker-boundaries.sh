#!/usr/bin/env bash
set -euo pipefail
repo_root=$(cd "$(dirname "$0")/../.." && pwd)
python3 - "$repo_root" <<'PY'
from pathlib import Path
import sys
root=Path(sys.argv[1])
arm=(root/'supervisor/arm64/cpu.lisp').read_text()
x86=(root/'supervisor/x86-64/cpu.lisp').read_text()
for text in (arm,x86):
    assert 'TODO:' not in text and 'FIXME:' not in text
for token in ('migration-aware quiescence','Debug-button stop/resume'):
    assert token in arm and token in x86, token
assert 'instruction/data cache coherence' in arm
assert 'range-aware invalidation' in x86
print('supervisor CPU marker boundaries passed')
PY
