#!/usr/bin/env bash
set -euo pipefail
repo_root=$(cd "$(dirname "$0")/../.." && pwd)
source="$repo_root/compiler/dynamic-extent.lisp"
python3 - "$source" <<'PY'
from pathlib import Path
import sys
text=Path(sys.argv[1]).read_text()
assert 'TODO: There\'s no way to tell' not in text
assert 'FIXME: There\'s no way to distinguish' not in text
for token in ('MAKE-ARRAY expansion always supplies an explicit initial element',
              'specialized element zero',
              'initialized explicitly on this non-zero path'):
    assert token in text, token
print('dynamic-extent array initialization boundary passed')
PY
