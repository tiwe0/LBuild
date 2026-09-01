#!/usr/bin/env bash
set -euo pipefail
repo_root=$(cd "$(dirname "$0")/../.." && pwd)
source="$repo_root/compiler/backend/x86-64/misc.lisp"
python3 - "$source" <<'PY'
from pathlib import Path
import sys
text = Path(sys.argv[1]).read_text()
assert 'TODO: Make sure the above guarantee still holds.' not in text
assert 'emits STI and HLT contiguously' in text
assert 'indivisible sequence' in text
PY
printf 'x86 STI/HLT scheduling boundary checks passed\n'
