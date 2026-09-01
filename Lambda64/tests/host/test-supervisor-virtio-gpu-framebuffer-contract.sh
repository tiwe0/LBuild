#!/usr/bin/env bash
set -euo pipefail
repo_root=$(cd "$(dirname "$0")/../.." && pwd)
source="$repo_root/supervisor/virtio-gpu.lisp"
python3 - "$source" <<'PY'
from pathlib import Path
import sys

text = Path(sys.argv[1]).read_text()
assert 'TODO: Support discontigious framebuffer.' not in text
body = text[text.index('(defun virtio::virtio-gpu-register'):]
for token in ('emits exactly one entry', 'contiguous physical base',
              'scatter/gather scanout plumbing', ':contiguous t',
              'virtio-gpu-resource-attach-backing gpu +virtio-gpu-framebuffer-resource-id+ 1'):
    assert token in body, token
PY
printf 'virtio-gpu framebuffer contract checks passed\n'
