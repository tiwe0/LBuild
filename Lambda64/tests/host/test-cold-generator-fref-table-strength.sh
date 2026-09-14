#!/usr/bin/env bash
# The cold generator's name->fref table must hold its keys strongly.
#
# Function names are symbols or (SETF symbol) lists.  A list name is freshly
# consed at each call site, so in a weak-key table nothing else references it
# and the host GC drops the entry -- always, over a multi-minute build.  A later
# reference creates a second, unbound fref and the image ships every (SETF ...)
# function undefined: the builtin setf wrappers, (SETF %OBJECT-REF-T), and the
# %%OBJECT-REF-* primitives chipz needs to decode a PNG.
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "$script_dir/../.." && pwd)
env_source=${COLD_ENV_SOURCE:-"$repo_root/tools/cold-generator2/environment.lisp"}

python3 - "$env_source" "${FREF_TABLE_MUTATION_RUN:-}" <<'PY'
from pathlib import Path
import re, sys

source = Path(sys.argv[1]).read_text(encoding="utf-8")
if sys.argv[2]:
    source = source.replace("(%name-frefs :initform (make-hash-table :test 'equal)",
                            "(%name-frefs :initform (make-weak-key-table :test 'equal)", 1)

m = re.search(r"\(%name-frefs :initform \(([a-z-]+) :test 'equal\)", source)
if not m:
    raise SystemExit("name->fref table initform not found")
if "weak" in m.group(1):
    raise SystemExit(
        f"name->fref table uses {m.group(1)}; (SETF ...) names are freshly "
        "consed lists and will be collected, shipping those functions undefined")
print(f"cold-generator fref table strength contract passed ({m.group(1)})")
PY

# Demonstrate the underlying host behaviour so the rationale stays checkable.
sbcl --noinform --disable-debugger --eval '
(let ((h (handler-case (make-hash-table :test (quote equal) :weakness :key)
           (error () nil))))
  (when h
    (setf (gethash (list (quote setf) (quote foo)) h) :bound)
    (sb-ext:gc :full t) (sb-ext:gc :full t)
    (when (gethash (list (quote setf) (quote foo)) h)
      (format t "~&NOTE: this host retains list keys in weak tables~%")))
  (sb-ext:quit))' >/dev/null 2>&1 || true

if [[ -z "${FREF_TABLE_MUTATION_RUN:-}" ]]; then
  if FREF_TABLE_MUTATION_RUN=1 bash "$0" >/dev/null 2>&1; then
    echo "fref table strength mutation unexpectedly survived" >&2
    exit 1
  fi
  echo "fref table strength mutation rejected"
fi
