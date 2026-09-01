#!/usr/bin/env bash
set -euo pipefail
script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "$script_dir/../.." && pwd)
source_file=${ARM64_CODEGEN_SOURCE:-"$repo_root/compiler/backend/arm64/codegen.lisp"}
python3 - "$source_file" "${ARM64_BOXSF_MUTATION_RUN:-}" <<'PY'
from pathlib import Path
import sys
s=Path(sys.argv[1]).read_text(encoding='utf-8'); start=s.index('(defmethod emit-lap (backend-function (instruction ir:box-single-float-instruction)'); end=s.index('\n\n(defmethod emit-lap',start); f=s[start:end]
if sys.argv[2]: f=f.replace('(let ((destination (ir:box-destination instruction))','(let ((destination :x9)',1)
for t in ['(let ((destination (ir:box-destination instruction))','(:gpr-64','(:fp-32','(lap:add ,destination ,destination ,tag)']:
 if t not in f: raise SystemExit('box-single-float codegen contract missing: '+t)
if ':x9' in f: raise SystemExit('temporary x9 register remains in box-single-float emitter')
print('ARM64 box-single-float no-temporary contract passed')
PY
if [[ -z "${ARM64_BOXSF_MUTATION_RUN:-}" ]]; then
 if ARM64_BOXSF_MUTATION_RUN=1 bash "$0" >/dev/null 2>&1; then echo 'ARM64 box-single-float mutation unexpectedly survived' >&2; exit 1; fi
 echo 'ARM64 box-single-float mutation rejected'
fi
