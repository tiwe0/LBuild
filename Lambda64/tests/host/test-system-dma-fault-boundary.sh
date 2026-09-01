#!/usr/bin/env bash
set -euo pipefail
repo_root=$(cd "$(dirname "$0")/../.." && pwd)
python3 - "$repo_root/system/error.lisp" <<'PY'
from pathlib import Path
import sys
s=Path(sys.argv[1]).read_text(); start=s.index('(defun raise-memory-fault'); form=s[start:s.index('\n\n', start)]
assert 'TODO' not in form and 'FIXME' not in form
assert 'DMA ownership metadata is not available' in form
assert "dma-buffer-expired" in form
print('DMA fault condition boundary passed')
PY
