#!/usr/bin/env bash
set -euo pipefail
repo_root=$(cd "$(dirname "$0")/../.." && pwd)
python3 - "$repo_root" <<'PY'
from pathlib import Path
import sys
root=Path(sys.argv[1])
instructions=(root/'compiler/backend/instructions.lisp').read_text()
compiler=(root/'compiler/backend/backend.lisp').read_text()
arm=(root/'compiler/backend/arm64/codegen.lisp').read_text()
x86=(root/'compiler/backend/x86-64/codegen.lisp').read_text()
assert '(make-dx-closure-environment instruction)' in instructions
assert '(second (lambda-information-environment-layout ast-lambda))' in compiler
assert 'make-dx-closure-environment instruction' in arm
assert 'make-dx-closure-environment instruction' in x86
# Current ABI is one opaque pointer in closure slot 2 on both targets.
assert '(:object ,(ir:make-dx-closure-result instruction) 2)' in x86
assert '(+ slots 0)' in arm
print('closure environment ABI boundary passed')
PY
