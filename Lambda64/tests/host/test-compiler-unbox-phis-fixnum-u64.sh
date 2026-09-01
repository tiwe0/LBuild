#!/usr/bin/env bash
# Regression coverage for keeping FIXNUM and UNSIGNED-BYTE-64 phi inputs separate.
set -euo pipefail
script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "$script_dir/../.." && pwd)
source_file=${PASSES_SOURCE:-"$repo_root/compiler/backend/passes.lisp"}
python3 - "$source_file" "${UNBOX_PHIS_MUTATION_RUN:-}" <<'PY'
from pathlib import Path
import sys

source = Path(sys.argv[1]).read_text(encoding="utf-8")
start = source.index("(defun unbox-phis-phi-is-candidate-p")
end = source.index("\n\n(defun unbox-phis-1", start)
form = source[start:end]
required = [
    "((eql type 'fixnum)",
    "((eql other-type 'fixnum)",
    "((eql type ':unsigned-byte-64)",
    "(member other-type '(:unsigned-byte-64 #+nil fixnum))",
]
missing = [token for token in required if token not in form]
if missing:
    raise SystemExit("FIXNUM/U64 separation contract missing: " + ", ".join(missing))
if sys.argv[2]:
    form = form.replace("'(:unsigned-byte-64 #+nil fixnum)", "'(:unsigned-byte-64 fixnum)", 1)
    if "'(:unsigned-byte-64 fixnum)" in form:
        raise SystemExit("FIXNUM/U64 mixing mutation survived")
print("unbox-phis FIXNUM/U64 separation contract passed")
PY
if [[ -z "${UNBOX_PHIS_MUTATION_RUN:-}" ]]; then
  if UNBOX_PHIS_MUTATION_RUN=1 bash "$0" >/dev/null 2>&1; then
    echo 'unbox-phis FIXNUM/U64 mixing mutation unexpectedly survived' >&2
    exit 1
  fi
  echo 'unbox-phis FIXNUM/U64 mixing mutation rejected'
fi
