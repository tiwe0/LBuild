#!/usr/bin/env bash
set -euo pipefail
repo_root=$(cd "$(dirname "$0")/../.." && pwd)
source="$repo_root/compiler/backend/passes.lisp"
python3 - "$source" <<'PY'
from pathlib import Path
import sys

text = Path(sys.argv[1]).read_text()
assert 'FIXME: This is only relevant for pairs that have' not in text
body = text
for token in ('conservative visibility check for boxed',
              'pairs with different', 'layouts (f32.4 vs f64.2',
              'simd-pack exclusion below',
              "(not (eql (box-type inst) 'mezzano.simd:simd-pack))"):
    assert token in body, token
PY
printf 'compiler box/unbox layout contract checks passed\n'
