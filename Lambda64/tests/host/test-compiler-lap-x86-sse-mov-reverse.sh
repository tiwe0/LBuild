#!/usr/bin/env bash
set -euo pipefail
script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "$script_dir/../.." && pwd)
source_file=${LAP_X86_SOURCE:-"$repo_root/compiler/lap-x86.lisp"}
python3 - "$source_file" "${LAP_X86_SSE_MOV_REVERSE_MUTATION_RUN:-}" <<'PY'
from pathlib import Path
import sys
s=Path(sys.argv[1]).read_text()
if sys.argv[2]:
    s=s.replace('(define-sse-float-op mov #x10 :packed nil :reverse t)',
                '(define-sse-float-op mov #x10 :packed nil :reverse nil)', 1)
required=[
    '(defmacro define-sse-float-op (name opcode &key (scalar t) (packed t) (single t) (double t) imm reverse)',
    '(define-sse-float-op mov #x10 :packed nil :reverse t)',
    '(when (and ,reverse (memory-operand-p lhs)',
    '(return-from instruction',
    "(modrm :xmm lhs rhs '(#x0F ,(1+ opcode)))" ,
]
missing=[x for x in required if x not in s]
if missing: raise SystemExit('x86 SSE MOV reverse contract missing: '+', '.join(missing))
if 'TODO: It goes the other way too.' in s: raise SystemExit('reverse-direction TODO marker remains')
print('x86 SSE MOV reverse-direction contract passed')
PY
if [[ -z "${LAP_X86_SSE_MOV_REVERSE_MUTATION_RUN:-}" ]]; then
  if LAP_X86_SSE_MOV_REVERSE_MUTATION_RUN=1 bash "$0" >/dev/null 2>&1; then
    echo 'x86 SSE MOV reverse mutation unexpectedly survived' >&2; exit 1
  fi
  echo 'x86 SSE MOV reverse mutation rejected'
fi
