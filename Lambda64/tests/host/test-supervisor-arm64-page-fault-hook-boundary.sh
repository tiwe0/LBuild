#!/usr/bin/env bash
set -euo pipefail
repo_root=$(cd "$(dirname "$0")/../.." && pwd)
source="$repo_root/supervisor/arm64/interrupts.lisp"
python3 - "$source" <<'PY'
from pathlib import Path
import sys

text = Path(sys.argv[1]).read_text()
assert "FIXME: This doesn't work when the hook was bound in SP_EL0" not in text
for token in ('Hooks run on the exception', 'SP_EL1 stack',
              'exception-return trampoline', 'restore the original SP_EL1',
              'supervisor-safe hooks'):
    assert token in text, token
PY
printf 'ARM64 page-fault hook boundary checks passed\n'
