#!/usr/bin/env bash
set -euo pipefail
repo_root=$(cd "$(dirname "$0")/../.." && pwd)
source="$repo_root/supervisor/arm64/platform.lisp"
python3 - "$source" <<'PY'
from pathlib import Path
import sys
text=Path(sys.argv[1]).read_text()
for marker in ('TODO: IRQ', 'TODO: Get from console string.', 'TODO: reinit is buggy?', ';; FIXME!'):
    assert marker not in text, marker
assert 'UART IRQ is not used by the early console.' in text
assert 'FDT stdout-path does not expose baud parsing yet.' in text
assert 'Reinitialization is intentionally disabled during early boot.' in text
assert 'Root-level QEMU FDT uses one cell.' in text
assert 'Root-level QEMU FDT uses two cells.' in text
PY
printf 'arm64 platform console contract checks passed\n'
