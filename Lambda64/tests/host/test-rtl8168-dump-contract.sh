#!/usr/bin/env bash
set -euo pipefail
repo_root=$(cd "$(dirname "$0")/../.." && pwd)
source="$repo_root/drivers/rtl8168.lisp"
python3 - "$source" <<'PY'
from pathlib import Path
import sys
text = Path(sys.argv[1]).read_text()
assert 'TODO: Get the remaining registers.' not in text
marker = 'Keep DUMP limited to the stable, read-only identity and multicast registers.'
assert marker in text
start = text.index('(defun dump (nic)')
body = text[start:text.index('(defun rtl8168-worker-body', start)]
assert body.count('rtl8168-reg/8') == 14, 'dump register surface changed unexpectedly'
PY
printf 'rtl8168 dump contract checks passed\n'
