#!/usr/bin/env bash
set -euo pipefail
repo_root=$(cd "$(dirname "$0")/../.." && pwd)
source="$repo_root/supervisor/x86-64/interrupts.lisp"
python3 - "$source" <<'PY'
from pathlib import Path
import sys
text = Path(sys.argv[1]).read_text()
assert 'TODO' not in text and 'FIXME' not in text and 'fixme' not in text
for token in ('APIC/IO-APIC setup requires a separate topology',
              'legacy dual 8259 PIC',
              'allocated lazily on the first boot',
              'serializer contract'):
    assert token in text, token
print('x86 interrupt boundary checks passed')
PY
