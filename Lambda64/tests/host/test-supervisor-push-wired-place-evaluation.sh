#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/../.." && pwd)
source="$repo_root/supervisor/support.lisp"
python3 - "$source" <<'PY'
from pathlib import Path
import sys

text = Path(sys.argv[1]).read_text(encoding="utf-8")
assert "multiple-evaluation of PLACE" not in text
start = text.index("(defmacro push-wired")
end = text.index("\n\n(defun string-length", start)
macro = text[start:end]
for token in ("get-setf-expansion place", "(gensym \"ITEM-\")", "(gensym \"NEW-\")", "sys.int::cons-in-area"):
    assert token in macro, token
assert macro.count("access-form") == 2
assert macro.count("store-form") == 2
PY
printf 'push-wired PLACE evaluation contract passed\n'
