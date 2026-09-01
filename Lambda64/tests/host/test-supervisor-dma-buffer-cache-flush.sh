#!/usr/bin/env bash
set -euo pipefail
repo_root=$(cd "$(dirname "$0")/../.." && pwd)
source="$repo_root/supervisor/dma-buffer.lisp"
cache_source="$repo_root/supervisor/arm64/cache.lisp"
python3 - "$source" "$cache_source" <<'PY'
from pathlib import Path
import sys
text=Path(sys.argv[1]).read_text()
cache=Path(sys.argv[2]).read_text()
assert 'TODO: do this properly' not in text
start=text.index('(defun dma-buffer-cache-flush')
body=text[start:text.index('(defun dma-buffer-physical-address', start)]
for token in ('check-type start (integer 0)', 'check-type end (integer 0)',
              'clean-and-invalidate-cache-range', 'dma-write-barrier',
              'DMA cache flush range is outside the buffer.'):
    assert token in body, token
assert '(logand base line-mask)' in cache
assert '(%dsb.osh)' in cache

def touched(base, length, line=64):
    if length <= 0:
        return []
    mask = ~(line - 1)
    start = base & mask
    end = (base + length + line - 1) & mask
    return list(range(start, end, line))
assert touched(0x1003, 1) == [0x1000]
assert touched(0x103f, 2) == [0x1000, 0x1040]
assert touched(0x1003, 0) == []
PY
printf 'dma-buffer cache flush checks passed\n'
