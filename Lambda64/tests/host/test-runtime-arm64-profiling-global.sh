#!/usr/bin/env bash
# Contract documenting the process-global allocation profiling flag on ARM64.
set -euo pipefail
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/../.." && pwd)
source_file=${ARM64_RUNTIME_SOURCE:-"$repo_root/runtime/runtime-arm64.lisp"}
python3 - "$source_file" <<'PY'
from pathlib import Path
import sys
s=Path(sys.argv[1]).read_text()
if 'FIXME' in s: raise SystemExit('runtime-arm64 FIXME remains')
if s.count('Allocation profiling is process-global (DEFGLOBAL)') != 2:
    raise SystemExit('expected both allocation profiling paths to document global semantics')
if s.count('(:symbol-global-cell *enable-allocation-profiling*)') != 2:
    raise SystemExit('allocation profiling must load the DEFGLOBAL cell')
print('runtime-arm64 allocation profiling global contract passed')
PY
