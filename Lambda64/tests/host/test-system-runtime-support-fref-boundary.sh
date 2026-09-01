#!/usr/bin/env bash
# Mutation-aware contract for function-reference publication boundaries.
set -euo pipefail
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/../.." && pwd)
source_file=${RUNTIME_SUPPORT_SOURCE:-"$repo_root/system/runtime-support.lisp"}
mutation=${RUNTIME_SUPPORT_FREF_MUTATION_RUN:-}
python3 - "$source_file" "$mutation" <<'PY'
from pathlib import Path
import sys

source = Path(sys.argv[1]).read_text(encoding="utf-8")
mutation = sys.argv[2]
# The setter's publication contract depends on both architecture activation
# helpers remaining present; removing either helper invalidates this boundary.
for helper in ("%activate-function-reference-full-path", "%activate-function-reference-fast-path"):
    if source.count(helper) < 3:
        raise SystemExit(f"missing activation helper contract: {helper}")
start = source.index("(defun (setf function-reference-function)")
# Extract one balanced Lisp form, ignoring strings and comments.
depth = 0
string = comment = esc = False
end = None
for i, c in enumerate(source[start:], start):
    if comment:
        if c == "\n": comment = False
        continue
    if string:
        if esc: esc = False
        elif c == "\\": esc = True
        elif c == '"': string = False
        continue
    if c == ";": comment = True
    elif c == '"': string = True
    elif c == "(": depth += 1
    elif c == ")":
        depth -= 1
        if depth == 0:
            end = i + 1
            break
if end is None:
    raise SystemExit("unterminated function-reference setter")
form = source[start:end]
if mutation:
    replacements = {
        "lock": "FIXME: FREF should be locked for the duration",
        "fence": "FIXME: Fences.",
        "cpu": "FIXME: Cross-CPU synchronization.",
    }
    marker = replacements.get(mutation, "")
    if marker:
        form = form.replace(marker, "resolved publication boundary", 1)

markers = (
    "FIXME: FREF should be locked for the duration",
    "FIXME: Fences.",
    "FIXME: Cross-CPU synchronization.",
)
for marker in markers:
    if marker not in form:
        raise SystemExit(f"missing function-reference publication marker: {marker}")

# Each setter branch must publish its target independently.  Counting the
# writes prevents a branch-local publication from being silently dropped while
# a later branch's write still satisfies the coarse ordering checks below.
if form.count("(%object-ref-t fref +fref-function+)") != 3:
    raise SystemExit("function-reference setter must publish exactly once per branch")
if form.count("%activate-function-reference") != 3:
    raise SystemExit("function-reference setter must activate exactly once per branch")

# The target field must be published before changing executable dispatch bytes.
for branch in ("((not value)", "((%object-of-type-p value", "(t"):
    pos = form.find(branch)
    if pos < 0:
        raise SystemExit(f"missing setter branch: {branch}")
    body = form[pos:]
    if "(%object-ref-t fref +fref-function+)" not in body:
        raise SystemExit(f"branch does not publish function field: {branch}")
    if body.find("(%object-ref-t fref +fref-function+)") > body.find("%activate-function-reference"):
        raise SystemExit(f"dispatch activation precedes target publication: {branch}")

print("runtime-support function-reference boundary contract passed (mutation-aware)")
PY
if [[ -z "$mutation" ]]; then
  for marker in lock fence cpu; do
    if RUNTIME_FREF_MUTATION_RUN=1 RUNTIME_SUPPORT_FREF_MUTATION_RUN="$marker" bash "$0" >/dev/null 2>&1; then
      echo "function-reference marker mutation unexpectedly survived: $marker" >&2
      exit 1
    fi
  done
  echo "function-reference boundary mutations rejected"
fi
