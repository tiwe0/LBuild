#!/usr/bin/env bash
set -euo pipefail
repo_root=$(cd "$(dirname "$0")/../.." && pwd)
source="$repo_root/supervisor/dma-buffer.lisp"
python3 - "$source" <<'PY'
from pathlib import Path
import sys
text=Path(sys.argv[1]).read_text()
assert 'TODO: Should this call into the pager' not in text
start=text.index(';; Allocation failure is deliberately non-blocking.')
body=text[start:start+400]
for token in ('non-blocking', 'no pager-reclaim hook', 'violate the pager ABI',
              'dma-buffer-allocation-error'):
    assert token in body or token in text, token
PY
printf 'dma-buffer allocation contract checks passed\n'
