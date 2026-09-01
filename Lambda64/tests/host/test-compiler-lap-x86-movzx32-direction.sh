#!/usr/bin/env bash
set -euo pipefail
script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "$script_dir/../.." && pwd)
source_file=${LAP_X86_SOURCE:-"$repo_root/compiler/lap-x86.lisp"}
python3 - "$source_file" "${LAP_X86_MOVZX32_MUTATION_RUN:-}" <<'PY'
from pathlib import Path
import sys
s=Path(sys.argv[1]).read_text()
if sys.argv[2]:
    s=s.replace('(modrm-two-classes :gpr-32 :gpr-64 dst src #x89)',
                '(modrm-two-classes :gpr-32 :gpr-64 src dst #x8B)', 1)
required=[
    '(define-instruction movzx32 (dst src)',
    '(modrm-two-classes :gpr-32 :gpr-64 dst src #x89)',
    'destination is kept in',
]
missing=[x for x in required if x not in s]
if missing: raise SystemExit('movzx32 direction contract missing: '+', '.join(missing))
if 'FIXME: This is r/m r' in s: raise SystemExit('movzx32 direction FIXME remains')
print('x86 MOVZX32 direction contract passed')
PY
if [[ -z "${LAP_X86_MOVZX32_MUTATION_RUN:-}" ]]; then
  if LAP_X86_MOVZX32_MUTATION_RUN=1 bash "$0" >/dev/null 2>&1; then
    echo 'x86 MOVZX32 direction mutation unexpectedly survived' >&2; exit 1
  fi
  echo 'x86 MOVZX32 direction mutation rejected'
fi
