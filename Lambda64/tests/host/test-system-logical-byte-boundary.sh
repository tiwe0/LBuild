#!/usr/bin/env bash
set -euo pipefail
repo_root=$(cd "$(dirname "$0")/../.." && pwd)
python3 - "$repo_root/system/numbers/logical.lisp" <<'PY'
from pathlib import Path
import sys
s=Path(sys.argv[1]).read_text()
assert 'FIXME' not in s
assert 'separate representation' in s
assert '(deftype byte' in s and '(defstruct (large-byte' in s
print('logical byte representation boundary passed')
PY
