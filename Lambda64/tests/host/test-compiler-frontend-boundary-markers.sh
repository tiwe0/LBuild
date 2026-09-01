#!/usr/bin/env bash
set -euo pipefail
script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "$script_dir/../.." && pwd)
python3 - "$repo_root" <<'PY'
from pathlib import Path
import sys
root = Path(sys.argv[1])
checks = {
    "0042": ("compiler/compiler.lisp", 'TODO: cannot compile functions defined outside the null lexical environment.'),
    "0054": ("compiler/keyword-arguments.lisp", "TODO: If &REST or &COUNT are special"),
    "0068": ("compiler/type-check.lisp", "TODO: Make this more efficient. Save values a la M-V-P1"),
}
for ident, (rel, marker) in checks.items():
    src = (root / rel).read_text()
    if marker not in src:
        raise SystemExit(f"TF-WI-{ident} marker unexpectedly missing")
    spec = (root.parent / "docs/modernization/todo-fixme/specs" / f"TF-WI-{ident}.md").read_text()
    for token in ("status: active", "owner: compiler", "review-cycle: 30d", f"TF-WI-{ident}"):
        if token not in spec:
            raise SystemExit(f"TF-WI-{ident} metadata missing: {token}")

resolved = {
    "0049": ("compiler/cross-compile.lisp", "TODO: Promote as appropriate."),
}
for ident, (rel, legacy_marker) in resolved.items():
    src = (root / rel).read_text()
    if legacy_marker in src:
        raise SystemExit(f"TF-WI-{ident} stale marker unexpectedly restored")
    spec = (root.parent / "docs/modernization/todo-fixme/specs" / f"TF-WI-{ident}.md").read_text()
    for token in ("owner: compiler", "review-cycle: 30d", f"TF-WI-{ident}"):
        if token not in spec:
            raise SystemExit(f"TF-WI-{ident} metadata missing: {token}")

# Mutation-aware guards: retain the safety boundary until the corresponding
# ABI/effect metadata exists, and prevent accidental weakening of it.
compiler = (root / "compiler/compiler.lisp").read_text()
if "(when env" not in compiler or "(error \"TODO: cannot compile functions defined outside" not in compiler:
    raise SystemExit("TF-WI-0042 lexical-environment rejection contract missing")
cross = (root / "compiler/cross-compile.lisp").read_text()
if "(defun complex (realpart imagpart)" not in cross or "Cannot promote" not in cross:
    raise SystemExit("TF-WI-0049 mixed short-float promotion implementation missing")
keywords = (root / "compiler/keyword-arguments.lisp").read_text()
if '"COUNT"' not in keywords or '"REST"' not in keywords or ":dynamic-extent t" not in keywords:
    raise SystemExit("TF-WI-0054 synthesized REST/COUNT contract missing")
control = (root / "compiler/simplify-control-flow.lisp").read_text()
if "defmethod simplify-control-flow-1 ((form ast-call)" not in control or "sys.int::%%unreachable" not in control:
    raise SystemExit("TF-WI-0063 no-return primitive contract missing")
types = (root / "compiler/type-check.lisp").read_text()
if "multiple-value-call" not in types or "(let ((req-values" not in types:
    raise SystemExit("TF-WI-0068 multiple-value preservation contract missing")
convert_ast = (root / "compiler/backend/convert-ast.lisp").read_text()
instructions_ast = (root / "compiler/backend/instructions.lisp").read_text()
if "make-instance 'save-multiple-instruction" not in convert_ast or "make-instance 'restore-multiple-instruction" not in convert_ast:
    raise SystemExit("TF-WI-0068 save/restore lowering boundary missing")
if "defclass save-multiple-instruction" not in instructions_ast or "defclass restore-multiple-instruction" not in instructions_ast:
    raise SystemExit("TF-WI-0068 save/restore IR definitions missing")

# TF-WI-0049 is implemented for exact 0/1 scalar promotion; reject a
# regression that restores the old assertion-only implementation.
if "TODO: Promote as appropriate." in cross or "assert (cross-support::cross-short-float-p realpart)" in cross:
    raise SystemExit("TF-WI-0049 stale assertion marker unexpectedly restored")
if "TODO: This is where no-return functions can be handled." in control:
    raise SystemExit("TF-WI-0063 stale no-return marker unexpectedly restored")
print("compiler frontend TODO/FIXME boundary contracts passed")
PY
