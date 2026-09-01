#!/usr/bin/env bash
set -euo pipefail
repo_root=$(cd "$(dirname "$0")/../.." && pwd)
source="$repo_root/supervisor/dma-buffer.lisp"
python3 - "$source" <<'PY'
from pathlib import Path
import sys
text=Path(sys.argv[1]).read_text()
assert 'TODO: do this properly' not in text
start=text.index('(defun dma-buffer-cache-flush')
body=text[start:text.index('(defun dma-buffer-physical-address', start)]
for token in ('check-type start (integer 0)', 'check-type end (integer 0)',
              'clean-and-invalidate-cache-range', 'dma-write-barrier',
              'DMA cache flush range is outside the buffer.'):
    assert token in body, token
PY
printf 'dma-buffer cache flush checks passed\n'
