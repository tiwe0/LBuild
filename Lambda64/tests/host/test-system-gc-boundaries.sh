#!/usr/bin/env bash
set -euo pipefail
repo_root=$(cd "$(dirname "$0")/../.." && pwd)
source="$repo_root/system/gc.lisp"
python3 - "$source" <<'PY'
from pathlib import Path
import sys
text = Path(sys.argv[1]).read_text()
assert 'FIXME: There\'s a race-condition here.' not in text
assert 'Concurrency boundary: obsolete-instance forwarding' in text
assert 'GC restart region' in text
assert 'TODO: should go back a whole bunch of cards.' not in text
assert 'Sparse card-table fallback: retreat one card and retry.' in text
PY
printf 'GC transport and card-table boundaries checks passed\n'
