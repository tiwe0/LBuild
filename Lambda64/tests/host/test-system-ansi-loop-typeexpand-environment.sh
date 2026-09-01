#!/usr/bin/env bash
# Regression coverage for LOOP typed initializers honoring the macro environment.
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "$script_dir/../.." && pwd)
source_file=${ANSI_LOOP_SOURCE:-"$repo_root/system/ansi-loop.lisp"}

python3 - "$source_file" "${ANSI_LOOP_TYPEEXPAND_MUTATION_RUN:-}" <<'PY'
from pathlib import Path
import sys

source = Path(sys.argv[1]).read_text(encoding="utf-8")
marker = "(defun loop-typed-init"
start = source.index(marker)
end = source.index("\n\n(defun loop-optional-type", start)
form = source[start:end]
if sys.argv[2]:
    form = form.replace("(sys.int::typeexpand data-type environment)",
                        "(sys.int::typeexpand data-type)", 1)

required = [
    "(defun loop-typed-init (data-type &optional (environment *loop-macro-environment*))",
    "(sys.int::typeexpand data-type environment)",
]
missing = [token for token in required if token not in form]
if "FIXME: This should pass the macro environment to typeexpand." in form:
    missing.append("FIXME marker removal")
if missing:
    raise SystemExit("LOOP typeexpand environment contract missing: " + ", ".join(missing))
print("LOOP typeexpand environment contract passed")
PY

if [[ -z "${ANSI_LOOP_TYPEEXPAND_MUTATION_RUN:-}" ]]; then
  if ANSI_LOOP_TYPEEXPAND_MUTATION_RUN=1 bash "$0" >/dev/null 2>&1; then
    echo "LOOP typeexpand environment mutation unexpectedly survived" >&2
    exit 1
  fi
  echo "LOOP typeexpand environment mutation rejected"
fi
