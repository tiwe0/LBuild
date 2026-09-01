#!/usr/bin/env bash
set -euo pipefail
repo_root=$(cd "$(dirname "$0")/../.." && pwd)
source="$repo_root/supervisor/sync.lisp"
python3 - "$source" <<'PY'
from pathlib import Path
import sys
text=Path(sys.argv[1]).read_text()
assert 'TODO: Move to write-locked uncontested if this is the only writer/reader.' not in text
start=text.index(';; Keep the contested mode while handing off.')
body=text[start:start+500]
for token in ('both wait queues', 'reader count atomically',
              'writer preference'):
    assert token in body, token
PY
printf 'rw-lock handoff contract checks passed\n'
