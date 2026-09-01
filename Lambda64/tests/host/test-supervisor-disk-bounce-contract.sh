#!/usr/bin/env bash
set -euo pipefail
repo_root=$(cd "$(dirname "$0")/../.." && pwd)
source="$repo_root/supervisor/disk.lisp"
python3 - "$source" <<'PY'
from pathlib import Path
import sys
text=Path(sys.argv[1]).read_text()
assert 'TODO: Do this without the bounce buffer.' not in text
start=text.index(';; Lisp arrays cannot be handed directly to disk drivers:')
body=text[start:start+500]
for token in ('object may move or be reclaimed', 'wired physical bounce buffer', 'pinned-buffer', 'DMA lifetime contract'):
    assert token in body, token
PY
printf 'disk bounce-buffer contract checks passed\n'
