#!/usr/bin/env bash
set -euo pipefail
script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "$script_dir/../.." && pwd)
python3 - "$repo_root" <<'PY'
from pathlib import Path
import sys
root=Path(sys.argv[1])
checks={
 '0021':('compiler/backend/canon.lisp','TODO: Insert debug variable updates where needed.'),
 '0025':('compiler/backend/instructions.lisp','TODO: Support arbitrary environments.'),
 '0029':('compiler/backend/ssa.lisp',"FIXME: The CFG doesn't quite represent NLX regions correctly"),
 '0009':('compiler/backend/arm64/codegen.lisp','TODO: Sort the layout so stack slots for values are all together and trim'),
 '0013':('compiler/backend/arm64/codegen.lisp','FIXME: Emit jump table as trailer.'),
 '0014':('compiler/backend/arm64/codegen.lisp',"FIXME: Don't recompute contours for each save instruction."),
 '0032':('compiler/backend/x86-64/codegen.lisp','TODO: Sort the layout so stack slots for values are all together and trim'),
 '0033':('compiler/backend/x86-64/codegen.lisp','FIXME: Emit jump table as trailer.'),
 '0040':('compiler/backend/x86-64/object.lisp','TODO: Use an integer vreg instead of rax here. x86-instruction must be extended to support converting allocated pregs to their 8-bit counterparts.'),
 '0041':('compiler/backend/x86-64/object.lisp','TODO: Use an integer vreg instead of rax here. x86-instruction must be extended to support converting allocated pregs to their 8-bit counterparts.'),
}
for ident,(rel,marker) in checks.items():
 src=(root/rel).read_text()
 if marker not in src: raise SystemExit(f'TF-WI-{ident} marker unexpectedly missing')
 if ident in {'0040','0041'} and src.count(marker) != 2:
  raise SystemExit('TF-WI-0040/0041 expected two distinct 8-bit preg markers')
 spec=(root.parent/'docs/modernization/todo-fixme/specs'/f'TF-WI-{ident}.md').read_text()
 for token in ('status: active','owner: compiler','review-cycle: 30d',f'# TF-WI-{ident}:'):
  if token not in spec: raise SystemExit(f'TF-WI-{ident} metadata missing: {token}')

# Mutation-aware guards for the three intentionally retained compiler
# boundaries.  These checks ensure a future edit cannot silently weaken the
# conservative behavior while the full ABI/debug fixture is still pending.
canon=(root/'compiler/backend/canon.lisp').read_text()
if ':destination (ir:call-result inst)' not in canon or ':source return-reg' not in canon:
 raise SystemExit('TF-WI-0021 canonical call-result move contract missing')
instructions=(root/'compiler/backend/instructions.lisp').read_text()
if '(list (make-dx-closure-function instruction)\n        (make-dx-closure-environment instruction))' not in instructions:
 raise SystemExit('TF-WI-0025 closure environment operand contract missing')
ssa=(root/'compiler/backend/ssa.lisp').read_text()
if '(typep inst \'begin-nlx-instruction)' not in ssa or 'setf rejected-transforms full-transforms' not in ssa:
 raise SystemExit('TF-WI-0029 conservative NLX rejection contract missing')

# TF-WI-0011/0012 are resolved by the GC-safe stack-slot swap lowering.
# Keep their active specs available for cold-image follow-up, but reject a
# regression that restores either unsafe marker into the implementation.
resolved={
 '0024':('compiler/backend/dominance.lisp','TODO: This numbers basic blocks'),
 '0010':('compiler/backend/arm64/codegen.lisp','FIXME: Support more than 2047 arguments (subs immediate limit).'),
 '0022':('compiler/backend/cfg.lisp','TODO: Break critical edges.'),
 '0023':('compiler/backend/cfg.lisp','TODO: Support switches too.'),
 '0028':('compiler/backend/register-allocation.lisp','TODO: Force 16-byte alignment.'),
 '0011':('compiler/backend/arm64/codegen.lisp','FIXME: This is wildly wrong and will cause the GC to lose live values.'),
 '0012':('compiler/backend/arm64/codegen.lisp',"FIXME: Fuckin' stop doing this!!!"),
 '0030':('compiler/backend/ssa.lisp','FIXME: Critical edges will prevent phi insertion'),
 '0034':('compiler/backend/x86-64/codegen.lisp',"FIXME: Don't recompute contours for each save instruction."),
 '0035':('compiler/backend/x86-64/codegen.lisp','TODO: Do this without a temporary integer register.'),
}
for ident,(rel,legacy_marker) in resolved.items():
 src=(root/rel).read_text()
 if legacy_marker in src: raise SystemExit(f'TF-WI-{ident} unsafe marker unexpectedly restored')
 spec=(root.parent/'docs/modernization/todo-fixme/specs'/f'TF-WI-{ident}.md').read_text()
 for token in ('status: active','owner: compiler','review-cycle: 30d',f'# TF-WI-{ident}:'):
  if token not in spec: raise SystemExit(f'TF-WI-{ident} metadata missing: {token}')
print('compiler backend TODO/FIXME boundary contracts passed')
PY
