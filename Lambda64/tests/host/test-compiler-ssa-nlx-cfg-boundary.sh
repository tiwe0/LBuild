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

# BEGIN-NLX's targets must remain edges in the graph SSA construction walks.
#
# TF-WI-0029 proposes a finer model: augment CALL instructions (where the
# asynchronous transfer actually occurs) with a separate SSA-specific successor
# relation, and feed that to dominance, liveness and phi placement -- step 3 of
# its design.  That step was never implemented.  Removing the edges from
# BEGIN-NLX without it left SSA walking a graph in which an NLX thunk has no
# predecessor at all, so DYNAMIC-CONTOURS never propagated any binding's live
# range into it and phi placement rejected every block reachable through it.
# Blocks past such a thunk then kept reading a variable's entry definition:
# ARM64 constant-folded loop accumulators to their initform and loops after a
# HANDLER-CASE that unwinds never terminated.  See
# tools/ci/test-arm64-nlx-ssa-codegen.sh, which cross-compiles the two variants
# and compares the emitted code.
#
# Restore these assertions to the TF-WI-0029 shape only together with step 3.
begin_method = instructions.split('(defmethod successors (function (instruction begin-nlx-instruction))', 1)[1].split('(defmethod', 1)[0]
assert 'begin-nlx-targets instruction' in begin_method, \
    'BEGIN-NLX must report its targets as successors; DYNAMIC-CONTOURS walks this'
cfg_section = cfg.split('(defun build-cfg', 1)[1].split('(defun discover-reachable-basic-blocks', 1)[0]
assert 'begin-nlx-targets' in cfg_section, \
    'BUILD-CFG must add NLX target edges; SSA phi placement depends on them'

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
