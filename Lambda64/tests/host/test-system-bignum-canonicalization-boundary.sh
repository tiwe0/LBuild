#!/usr/bin/env bash
set -euo pipefail
repo_root=$(cd "$(dirname "$0")/../.." && pwd)
python3 - "$repo_root/system/numbers/bignum-x86-64.lisp" <<'PY'
from pathlib import Path
import sys
s=Path(sys.argv[1]).read_text(); start=s.index('(define-lap-function %%canonicalize-bignum')
form=s[start:]
assert 'TODO' not in form and 'FIXME' not in form
assert 'stack-allocated bignums' in form
assert 'maybe-resize-bignum' in form
print('bignum canonicalization allocation boundary passed')
PY
