#!/usr/bin/env bash
set -euo pipefail
script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "$script_dir/../.." && pwd)
python3 - "$repo_root" <<'PY'
from pathlib import Path
import sys
src=(Path(sys.argv[1])/'compiler/pass1.lisp').read_text()
required=['((eql fn \'error)', " :name 'sys.int::%%unreachable", 'the explicit %%UNREACHABLE tail']
missing=[x for x in required if x not in src]
if missing: raise SystemExit('pass1 ERROR terminator contract missing: '+', '.join(missing))
if 'FIXME: Bit of a hack.' in src: raise SystemExit('legacy FIXME remains')
print('pass1 ERROR terminator contract passed')
PY
