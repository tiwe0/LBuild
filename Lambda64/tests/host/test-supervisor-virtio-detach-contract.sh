#!/usr/bin/env bash
set -euo pipefail
repo_root=$(cd "$(dirname "$0")/../.." && pwd)
source="$repo_root/supervisor/virtio.lisp"
python3 - "$source" <<'PY'
from pathlib import Path
import sys
text=Path(sys.argv[1]).read_text()
assert 'TODO: Maybe reprobe the device?' not in text
start=text.index('(defun virtio-driver-detached')
body=text[start:]
for token in ('Do not automatically reprobe here.',
              'must first be\n    ;; reset by its transport',
              'Registry registration/probe remains the explicit',
              '+virtio-status-failed+'):
    assert token in body, token
PY
printf 'virtio detach contract checks passed\n'
