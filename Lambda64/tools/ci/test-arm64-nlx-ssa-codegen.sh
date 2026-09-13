#!/usr/bin/env bash
# Regression: assignments must survive a non-local-exit landing pad.
#
# BEGIN-NLX's targets are CFG edges even though control reaches them
# asynchronously.  DYNAMIC-CONTOURS walks SUCCESSORS and BUILD-CFG to propagate
# each binding's live range; if the NLX target edges are dropped, every block
# reachable only through a thunk falls outside the contour, SSA phi placement
# rejects it, and the block keeps reading the variable's entry definition.  A
# loop that assigns such a variable after a HANDLER-CASE that actually unwinds
# then has its assignments constant-folded away and never terminates.
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "${1:-$script_dir/../..}" && pwd)
quicklisp_setup=${LAMBDA64_QUICKLISP_SETUP:-"$HOME/quicklisp/setup.lisp"}

[[ -s "$quicklisp_setup" ]] || {
    echo "Quicklisp setup not found: $quicklisp_setup" >&2
    exit 2
}

tmp=$(mktemp -d "${TMPDIR:-/tmp}/lambda64-nlx-ssa.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

# NO-UNWIND is the reference: same shape, but the sibling initform cannot
# transfer control.  UNWIND must compile to the same kind of loop.
cat > "$tmp/probe.lisp" <<'EOF'
(in-package :mezzano.internals)
(defun nlx-ssa-probe-unwind (l)
  (let ((caught (ignore-errors (error "boom")))
        (c 0))
    (declare (ignore caught))
    (dolist (e l) (declare (ignore e)) (setf c (1+ c)))
    c))
(defun nlx-ssa-probe-no-unwind (l)
  (let ((caught nil)
        (c 0))
    (declare (ignore caught))
    (dolist (e l) (declare (ignore e)) (setf c (1+ c)))
    c))
EOF

cat > "$tmp/trace.lisp" <<'EOF'
(require :asdf)
(load (uiop:getenv "LAMBDA64_QUICKLISP_SETUP"))
(push (pathname (uiop:getenv "LAMBDA64_REPO_ROOT")) asdf:*central-registry*)
(asdf:load-system :lispos)
(cold-generator:set-up-cross-compiler :architecture :arm64)
(let ((mezzano.compiler::*trace-asm* t)
      (mezzano.compiler::*target-architecture* :arm64))
  (mezzano.compiler::cross-compile-file
   (pathname (uiop:getenv "LAMBDA64_PROBE_SOURCE"))
   :output-file (pathname (uiop:getenv "LAMBDA64_TRACE_OUTPUT"))))
(sb-ext:quit)
EOF

(
    cd "$repo_root"
    LAMBDA64_QUICKLISP_SETUP="$quicklisp_setup" \
    LAMBDA64_REPO_ROOT="$repo_root/" \
    LAMBDA64_PROBE_SOURCE="$tmp/probe.lisp" \
    LAMBDA64_TRACE_OUTPUT="$tmp/probe.llf" \
        sbcl --script "$tmp/trace.lisp" > "$tmp/trace.log" 2>&1
)

python3 - "$tmp/trace.log" <<'PY'
import re, sys
log = open(sys.argv[1]).read()

def body(name):
    start = log.index(f"\n{name}:\n")
    end = log.index("LITERAL-POOL", start)
    return log[start:end]

for name in ("NLX-SSA-PROBE-UNWIND", "NLX-SSA-PROBE-NO-UNWIND"):
    if f"\n{name}:\n" not in log:
        raise SystemExit(f"{name} missing from the ARM64 trace")

# The accumulator's increment must read a live register.  A materialised zero
# feeding the increment means the store was dropped and the entry value was
# constant-propagated into the loop.
pattern = re.compile(
    r"ORR\s+:(X\d+)\s+:XZR\s+:XZR\)\s*\)?\s*\n(?:.*\n){0,3}?.*ADDS\s+:\1\s+:\1\s+2\)")

unwind = body("NLX-SSA-PROBE-UNWIND")
reference = body("NLX-SSA-PROBE-NO-UNWIND")

if pattern.search(reference):
    raise SystemExit("reference variant already constant-folds; test is not meaningful")
if pattern.search(unwind):
    raise SystemExit(
        "accumulator constant-folded after a non-local-exit landing pad: "
        "BEGIN-NLX target edges are missing from the CFG, so SSA dropped the phi")
print("ARM64 NLX/SSA assignment-liveness codegen contract passed")
PY
