#!/usr/bin/env bash
set -euo pipefail
repo_root=$(cd "$(dirname "$0")/../.." && pwd)
source="$repo_root/supervisor/entry.lisp"
python3 - "$source" <<'PY'
from pathlib import Path
import sys

text = Path(sys.argv[1]).read_text()
assert 'FIXME: Should not be here.' not in text
for token in ('reboot shim remains in this entry module',
              'stable platform lifecycle hook',
              '(defun reboot ()', '(platform-reboot)'):
    assert token in text, token
PY
printf 'supervisor entry reboot boundary checks passed\n'
