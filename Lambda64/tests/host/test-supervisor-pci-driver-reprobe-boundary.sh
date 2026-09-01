#!/usr/bin/env bash
set -euo pipefail
repo_root=$(cd "$(dirname "$0")/../.." && pwd)
source="$repo_root/supervisor/pci.lisp"
python3 - "$source" <<'PY'
from pathlib import Path
import sys

text = Path(sys.argv[1]).read_text()
assert 'TODO: Detach current driver and reprobe?' not in text
for token in ('PCI drivers expose only a probe callback',
              'no detach/reset lifecycle hook',
              'explicit teardown',
              '(error "Incompatible redefinition of virtio driver ~S." name)'):
    assert token in text, token
PY
printf 'PCI driver reprobe boundary checks passed\n'
