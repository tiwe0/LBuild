#!/usr/bin/env bash
set -euo pipefail
repo_root=$(cd "$(dirname "$0")/../.." && pwd)
source="$repo_root/supervisor/virtio.lisp"
python3 - "$source" <<'PY'
from pathlib import Path
import sys
text=Path(sys.argv[1]).read_text()
assert 'TODO: This should notify drivers that devices are gone.' not in text
start=text.index(';; Device objects from a previous boot are invalidated')
body=text[start:start+500]
for token in ('previous boot', 'invalidated by the boot epoch',
              'stale transport state', 'VIRTIO-DRIVER-DETACHED'):
    assert token in body, token
PY
printf 'virtio init detach contract checks passed\n'
