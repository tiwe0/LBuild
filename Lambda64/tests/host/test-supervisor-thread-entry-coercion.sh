#!/usr/bin/env bash
# A thread's initial function must be coerced before the low-level call.
#
# MAKE-THREAD's contract is (OR FUNCTION SYMBOL) and most GUI entry points pass
# a symbol.  %CALL-FUNCTION-NOARGS is a bare LDR of +FUNCTION-ENTRY-POINT+ plus
# BLR: given a symbol it loads the symbol's first slot, a tagged value, and
# branches to it.  The thread then dies with a PC alignment fault far from the
# call site.  FUNCALL performed this coercion; the direct primitive does not.
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "$script_dir/../.." && pwd)
thread_source=${THREAD_SOURCE:-"$repo_root/supervisor/thread.lisp"}

python3 - "$thread_source" "$repo_root" "${THREAD_ENTRY_MUTATION_RUN:-}" <<'PY'
from pathlib import Path
import re, sys

source = Path(sys.argv[1]).read_text(encoding="utf-8")
root = Path(sys.argv[2])
if sys.argv[3]:
    source = source.replace("(sys.int::%call-function-noargs (sys.int::%coerce-to-callable function))",
                            "(sys.int::%call-function-noargs function)", 1)

# The declared contract must still admit symbols; otherwise this test is moot.
if not re.search(r"\(check-type function \(or function symbol\)\)", source):
    raise SystemExit("MAKE-THREAD no longer accepts symbols; revisit this contract")

start = source.index("(defun call-function-noargs-traced")
body = source[start:source.index("(defun ", start + 10)]
if "%coerce-to-callable" not in body:
    raise SystemExit(
        "thread entry calls %CALL-FUNCTION-NOARGS without coercing; a symbol "
        "initial function would branch to a tagged value")

# And there really are symbol callers, so the coercion is load-bearing.
callers = 0
for path in root.rglob("*.lisp"):
    try:
        callers += len(re.findall(r"make-thread\s+'", path.read_text(encoding="utf-8", errors="ignore")))
    except OSError:
        pass
if callers == 0:
    raise SystemExit("no symbol MAKE-THREAD callers found; contract may have moved")
print(f"thread entry coercion contract passed ({callers} symbol callers)")
PY

if [[ -z "${THREAD_ENTRY_MUTATION_RUN:-}" ]]; then
  if THREAD_ENTRY_MUTATION_RUN=1 bash "$0" >/dev/null 2>&1; then
    echo "thread entry coercion mutation unexpectedly survived" >&2
    exit 1
  fi
  echo "thread entry coercion mutation rejected"
fi
