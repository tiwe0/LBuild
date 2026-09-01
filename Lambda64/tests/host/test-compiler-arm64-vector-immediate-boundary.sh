#!/usr/bin/env bash
set -euo pipefail
script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "$script_dir/../.." && pwd)
python3 - "$repo_root" <<'PY'
from pathlib import Path
import sys
src=(Path(sys.argv[1])/'compiler/backend/arm64/arm64.lisp').read_text()
for token in ('(defun code-for-direct-vector-imm', ':lsl 0', ':lsl 8', ':lsl 16', ':lsl 24', 'canonical zero-shift'):
    if token not in src: raise SystemExit(f'ARM64 vector immediate boundary missing: {token}')
if 'TODO: There are more possible variants with the :MSL shift type' in src:
    raise SystemExit('legacy MSL TODO remains')
print('ARM64 vector immediate boundary passed')
PY
