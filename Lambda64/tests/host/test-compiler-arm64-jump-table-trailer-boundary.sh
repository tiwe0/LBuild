#!/usr/bin/env bash
set -euo pipefail
repo_root=$(cd "$(dirname "$0")/../.." && pwd)
source="$repo_root/compiler/backend/arm64/codegen.lisp"
spec="$repo_root/../docs/modernization/todo-fixme/specs/TF-WI-0013.md"
python3 - "$source" "$spec" <<'PY'
from pathlib import Path
import sys
source = Path(sys.argv[1]).read_text()
spec = Path(sys.argv[2]).read_text()
assert 'FIXME: Emit jump table as trailer.' not in source
for token in ('*jump-tables*', 'Emit NLX dispatch tables after the function body',
              '(lap:adr :x9 ,jump-table)', 'jump-table)', '(:d64/le (- ,(resolve-label target) ,jump-table))'):
    assert token in source, token
for token in ('no function-level trailer channel', 'flat instruction list',
              'Minimal implementation design', 'cold serialization',
              'out-of-range PC-relative references'):
    assert token in spec, token
PY
printf 'ARM64 NLX jump-table trailer boundary checks passed\n'
