#!/usr/bin/env bash
set -euo pipefail
repo_root=$(cd "$(dirname "$0")/../.." && pwd)
source="$repo_root/supervisor/arm64/thread.lisp"
python3 - "$source" <<'PY'
from pathlib import Path
import sys
text=Path(sys.argv[1]).read_text()
assert 'FIXME: Make sure the stack is paged in' not in text
start=text.index(';; The pager invokes this helper only after queuing')
body=text[start:start+500]
for token in ('pager-request path', 'no resumable call trampoline',
              'normal pager path', 'speculative stack touching'):
    assert token in body, token
PY
printf 'arm64 thread stack residency contract checks passed\n'
