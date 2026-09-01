#!/usr/bin/env bash
set -euo pipefail
repo_root=$(cd "$(dirname "$0")/../.." && pwd)
source="$repo_root/supervisor/pager.lisp"
python3 - "$source" <<'PY'
from pathlib import Path
import sys
text=Path(sys.argv[1]).read_text()
assert 'TODO: Purge empty page table levels.' not in text
start=text.index(';; Empty page-table-level reclamation is intentionally not attempted')
body=text[start:start+550]
for token in ('under the VM write lock', 'TLB shootdowns', 'parent metadata', 'deferred shootdown-aware'):
    assert token in body, token
PY
printf 'pager purge contract checks passed\n'
