#!/usr/bin/env bash
set -euo pipefail
repo_root=$(cd "$(dirname "$0")/../.." && pwd)
source="$repo_root/supervisor/x86-64/platform.lisp"
python3 - "$source" <<'PY'
from pathlib import Path
import sys
text = Path(sys.argv[1]).read_text()
assert 'TODO' not in text and 'FIXME' not in text
assert 'fixed PC-compatible COM1 profile' in text
assert 'boot-configuration API should supply the port, IRQ, and baud settings.' in text
assert '(let ((serial-port-io-base #x3F8))' in text
assert 'initialize-debug-serial serial-port-io-base 0' in text
assert '4 115200' in text
PY
printf 'x86 platform console contract checks passed\n'
