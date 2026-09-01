#!/usr/bin/env bash
set -euo pipefail
repo_root=$(cd "$(dirname "$0")/../.." && pwd)
source="$repo_root/supervisor/virtio.lisp"
python3 - "$source" <<'PY'
from pathlib import Path
import sys

text = Path(sys.argv[1]).read_text()
assert 'TODO: Maybe detach current driver and reprobe?' not in text
for token in ('no detach/reset callback', 'incompatible',
              'clearing claims', 'explicit teardown'):
    assert token in text, token
PY
printf 'virtio registration boundary checks passed\n'
