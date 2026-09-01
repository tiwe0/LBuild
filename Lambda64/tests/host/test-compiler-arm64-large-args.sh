#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source_file=${ARM64_CODEGEN_SOURCE:-"$script_dir/../../compiler/backend/arm64/codegen.lisp"}

python3 - "$source_file" <<'PY'
from pathlib import Path
import sys

source = Path(sys.argv[1]).read_text()
start = source.index("(defun emit-argument-check")
end = source.index("(defun emit-dx-rest-list", start)
body = source[start:end]

assert "((emit-count-sub (destination source count)" in body, "large argument fallback helper missing"
assert "(load-literal :x10 raw-count)" in body, "large argument count is not materialized"
assert "(lap:subs ,destination ,source :x10)" in body, "register SUBS fallback missing"
assert "FIXME: Support more than 2047 arguments" not in body, "large argument marker still present"

# Every argument-count check goes through the helper, so no oversized tagged
# count can reach the immediate-only SUBS encoding directly.
assert body.count("(emit-count-sub ") >= 4
print("ARM64 large argument count lowering contract passed")
PY
