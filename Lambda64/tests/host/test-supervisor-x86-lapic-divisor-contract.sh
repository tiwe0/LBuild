#!/usr/bin/env bash
set -euo pipefail
repo_root=$(cd "$(dirname "$0")/../.." && pwd)
source="$repo_root/supervisor/x86-64/cpu.lisp"
python3 - "$source" <<'PY'
from pathlib import Path
import sys
text=Path(sys.argv[1]).read_text()
assert 'TODO: Be more clever when picking the divisor.' not in text
start=text.index(';; Keep the fixed divide-by-16 setting')
body=text[start:start+400]
for token in ('fixed divide-by-16', 'averages several ticks',
              'reprogramming every active CPU timer atomically'):
    assert token in body, token
assert '(setf (lapic-reg +lapic-reg-timer-divide-configuration+) #x03)' in text
PY
printf 'x86 LAPIC divisor contract checks passed\n'
