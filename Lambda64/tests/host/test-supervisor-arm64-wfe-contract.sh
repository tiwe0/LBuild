#!/usr/bin/env bash
set -euo pipefail
repo_root=$(cd "$(dirname "$0")/../.." && pwd)
interrupts="$repo_root/supervisor/arm64/interrupts.lisp"
cpu="$repo_root/supervisor/arm64/cpu.lisp"
python3 - "$interrupts" "$cpu" <<'PY'
from pathlib import Path
import sys
interrupts=Path(sys.argv[1]).read_text(); cpu=Path(sys.argv[2]).read_text()
assert 'TODO: Use SEV/WFE hints' not in interrupts
assert 'FIXME: Use WFE/SEV instead of this spin-loop.' not in cpu
assert 'do not publish a matching' in interrupts
assert 'every decrement below to issue a matching SEV' in cpu
PY
printf 'arm64 WFE/SEV contract checks passed\n'
