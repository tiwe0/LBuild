#!/usr/bin/env bash
set -euo pipefail
repo_root=$(cd "$(dirname "$0")/../.." && pwd)
source="$repo_root/supervisor/virtio-pci.lisp"
python3 - "$source" <<'PY'
from pathlib import Path
import sys
text = Path(sys.argv[1]).read_text()
assert 'TODO: Operate transitional devices in normal mode.' not in text
assert 'TODO: Test the VIRTIO_F_VERSION_1 feature.' not in text
assert 'require negotiating VIRTIO_F_VERSION_1' in text
assert 'legacy BAR-0 contract' in text
PY
printf 'virtio-pci transitional contract checks passed\n'
