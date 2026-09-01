#!/usr/bin/env bash
set -euo pipefail
repo_root=$(cd "$(dirname "$0")/../.." && pwd)
source="$repo_root/compiler/backend/ssa.lisp"
spec="$repo_root/../docs/modernization/todo-fixme/specs/TF-WI-0029.md"
cfg="$repo_root/compiler/backend/cfg.lisp"
instructions="$repo_root/compiler/backend/instructions.lisp"
analysis="$repo_root/compiler/backend/analysis.lisp"
python3 - "$source" "$spec" "$cfg" "$instructions" "$analysis" <<'PY'
from pathlib import Path
import sys
source = Path(sys.argv[1]).read_text()
spec = Path(sys.argv[2]).read_text()
cfg = Path(sys.argv[3]).read_text()
instructions = Path(sys.argv[4]).read_text()
analysis = Path(sys.argv[5]).read_text()

# NLX establishment is not a control transfer. Its target thunks are
# asynchronous successors of calls, not ordinary dominance/CFG edges.
begin_method = instructions.split('(defmethod successors (function (instruction begin-nlx-instruction))', 1)[1].split('(defmethod', 1)[0]
assert '(call-next-method)' in begin_method
assert 'begin-nlx-targets instruction' not in begin_method
cfg_section = cfg.split('(defun build-cfg', 1)[1].split('(defun discover-reachable-basic-blocks', 1)[0]
assert 'begin-nlx-targets' not in cfg_section

# Candidate discovery uses dynamic contours and rejects only bindings live at
# each NLX boundary; the old unconditional bail-out and disabled #+(or)
# implementation must not return.
assert '#+(or)' not in source
for token in ('dynamic-contours backend-function', 'intersection live full-transforms',
              'set-difference full-transforms live', 'rejected-transforms',
              'full-transforms'):
    assert token in source, token

# Actual CFG/liveness retains asynchronous edges from calls to all live NLX
# targets, including nested contours.
assert 'compute-actual-successors' in analysis
assert 'begin-nlx-targets c' in analysis
PY
printf 'SSA NLX CFG boundary checks passed\n'
