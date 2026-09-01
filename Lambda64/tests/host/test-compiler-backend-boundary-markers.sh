#!/usr/bin/env bash
set -euo pipefail
script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "$script_dir/../.." && pwd)
python3 - "$repo_root" <<'PY'
from pathlib import Path
import sys
root=Path(sys.argv[1])
checks={
 '0022':('compiler/backend/cfg.lisp','TODO: Break critical edges.'),
 '0023':('compiler/backend/cfg.lisp','TODO: Support switches too.'),
 '0024':('compiler/backend/dominance.lisp','TODO: This numbers basic blocks'),
 '0025':('compiler/backend/instructions.lisp','TODO: Support arbitrary environments.'),
 '0028':('compiler/backend/register-allocation.lisp','TODO: Force 16-byte alignment.'),
 '0029':('compiler/backend/ssa.lisp',"FIXME: The CFG doesn't quite represent NLX regions correctly"),
 '0030':('compiler/backend/ssa.lisp','FIXME: Critical edges will prevent phi insertion'),
}
for ident,(rel,marker) in checks.items():
 src=(root/'Lambda64'/rel).read_text()
 if marker not in src: raise SystemExit(f'TF-WI-{ident} marker unexpectedly missing')
 spec=(root/'docs/modernization/todo-fixme/specs'/f'TF-WI-{ident}.md').read_text()
 for token in ('status: active','owner: compiler','review-cycle: 30d',f'# TF-WI-{ident}:'):
  if token not in spec: raise SystemExit(f'TF-WI-{ident} metadata missing: {token}')
print('compiler backend TODO/FIXME boundary contracts passed')
PY
