#!/usr/bin/env bash
set -euo pipefail
repo_root=$(cd "$(dirname "$0")/../.." && pwd)
pager="$repo_root/supervisor/pager.lisp"
interrupts="$repo_root/supervisor/interrupts.lisp"
cdrom="$repo_root/supervisor/cdrom.lisp"
python3 - "$pager" "$interrupts" "$cdrom" <<'PY'
from pathlib import Path
import sys
pager = Path(sys.argv[1]).read_text()
interrupts = Path(sys.argv[2]).read_text()
cdrom = Path(sys.argv[3]).read_text()
for token in ('Early-boot callers are responsible', 'TF-WI-0261',
              'zero-fill transition intentionally releases', 'TF-WI-0262/0263'):
    assert token in pager, token
assert 'TODO:' not in pager and 'FIXME:' not in pager
assert 'Keep CAS until the ARM64 write form provides release semantics.' in interrupts
assert 'TF-WI-0259' in interrupts
assert 'FIXME:' not in interrupts
assert 'one data track' in cdrom
assert 'TF-WI-0248' in cdrom
assert 'FIXME:' not in cdrom
PY
printf 'pager and spinlock boundary checks passed\n'
