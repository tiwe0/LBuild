#!/usr/bin/env bash
set -euo pipefail
repo_root=$(cd "$(dirname "$0")/../.." && pwd)
source="$repo_root/system/cold-start.lisp"
python3 - "$source" <<'PY'
from pathlib import Path
import sys
text = Path(sys.argv[1]).read_text()
assert 'FIXME: These should be weak' not in text
assert 'structured (package/name) keys' in text
assert 'dedicated SETF/CAS weak tables' in text
assert ':weakness :key' in text
PY
printf 'Cold-start documentation table boundary checks passed\n'
