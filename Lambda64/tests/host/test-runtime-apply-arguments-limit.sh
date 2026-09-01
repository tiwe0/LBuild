#!/usr/bin/env bash
# Regression coverage for %APPLY's CALL-ARGUMENTS-LIMIT guard.
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "$script_dir/../.." && pwd)
source_file=${APPLY_SOURCE:-"$repo_root/runtime/runtime-x86-64.lisp"}
limit_source="$repo_root/system/stuff.lisp"

python3 - "$source_file" "$limit_source" "${APPLY_LIMIT_MUTATION_RUN:-}" <<'PY'
from pathlib import Path
import sys

source = Path(sys.argv[1]).read_text(encoding="utf-8")
limit_source = Path(sys.argv[2]).read_text(encoding="utf-8")
start = source.index("(sys.int::define-lap-function %apply")
depth = 0
string = comment = escape = False
for i in range(start, len(source)):
    c = source[i]
    if comment:
        if c == "\n": comment = False
    elif string:
        if escape: escape = False
        elif c == '\\': escape = True
        elif c == '"': string = False
    elif c == ';': comment = True
    elif c == '"': string = True
    elif c == '(': depth += 1
    elif c == ')':
        depth -= 1
        if depth == 0:
            form = source[start:i + 1]
            break
else:
    raise SystemExit("unterminated %apply form")

if sys.argv[3]:
    form = form.replace("(sys.lap-x86:jae too-many-arguments)", "(sys.lap-x86:ja too-many-arguments)", 1)

required = [
    "sys.int::call-arguments-limit",
    "(sys.lap-x86:cmp32 :ecx #.(ash sys.int::call-arguments-limit",
    "(sys.lap-x86:jae too-many-arguments)",
    "too-many-arguments",
    "(:constant program-error)",
]
for anchor in required:
    if anchor not in form:
        raise SystemExit(f"CALL-ARGUMENTS-LIMIT contract missing: {anchor}")

check = form.index("(sys.lap-x86:cmp32 :ecx #.(ash sys.int::call-arguments-limit")
branch = form.index("(sys.lap-x86:jae too-many-arguments)")
advance = form.index(";; Advance.")
if not check < branch < advance:
    raise SystemExit("argument-limit guard must run before list traversal advances")

# CALL-ARGUMENTS-LIMIT is an exclusive upper bound.
import re
match = re.search(r"\(defconstant call-arguments-limit (\d+)\)", limit_source)
if not match:
    raise SystemExit("CALL-ARGUMENTS-LIMIT definition missing")
limit = int(match.group(1))
accepted = lambda count: count < limit
if not accepted(limit - 1) or accepted(limit):
    raise SystemExit("argument-limit boundary contract failed")
print("%apply CALL-ARGUMENTS-LIMIT contract passed")
PY

if [[ -z "${APPLY_LIMIT_MUTATION_RUN:-}" ]]; then
  if APPLY_LIMIT_MUTATION_RUN=1 bash "$0" >/dev/null 2>&1; then
    echo "%apply CALL-ARGUMENTS-LIMIT mutation unexpectedly survived" >&2
    exit 1
  fi
  echo "%apply CALL-ARGUMENTS-LIMIT mutation rejected"
fi
