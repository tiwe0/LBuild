#!/usr/bin/env bash
set -euo pipefail
repo_root=$(cd "$(dirname "$0")/../.." && pwd)
source="$repo_root/compiler/backend/ssa.lisp"
spec="$repo_root/../docs/modernization/todo-fixme/specs/TF-WI-0029.md"
python3 - "$source" "$spec" <<'PY'
from pathlib import Path
import sys
source = Path(sys.argv[1]).read_text()
spec = Path(sys.argv[2]).read_text()
assert "FIXME: The CFG doesn't quite represent NLX regions correctly" in source
for token in ('#+(or)', 'dynamic-contours backend-function',
              'rejected-transforms', 'full-transforms'):
    assert token in source, token
for token in ('successors` generic', 'ordinary fall-through continuation',
              'SSA-specific successor relation', 'nested NLX targets',
              'normal continuation edge', 'dynamic-contours` records',
              'construct-ssa` invokes candidate discovery'):
    assert token in spec, token
PY
printf 'SSA NLX CFG boundary checks passed\n'
