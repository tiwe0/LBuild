#!/usr/bin/env bash
set -euo pipefail
repo_root=$(cd "$(dirname "$0")/../.." && pwd)
source="$repo_root/supervisor/pager.lisp"
python3 - "$source" <<'PY'
from pathlib import Path
import sys
text=Path(sys.argv[1]).read_text()
assert "TODO: Shouldn't panic at all" not in text
start=text.index(";; Keep unhandled faults on the pager's panic path")
body=text[start:start+550]
for token in ('debugger-thread', 'saved frame', 'VM lock ownership', 'panic policy atomically'):
    assert token in body, token
PY
printf 'pager panic contract checks passed\n'
