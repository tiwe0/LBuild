#!/usr/bin/env bash
# Regression coverage for LOOP typed initializers of sized vectors.
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "$script_dir/../.." && pwd)
source_file=${ANSI_LOOP_SOURCE:-"$repo_root/system/ansi-loop.lisp"}

python3 - "$source_file" "${ANSI_LOOP_TYPED_INIT_VECTOR_MUTATION_RUN:-}" <<'PY'
from pathlib import Path
import sys

source = Path(sys.argv[1]).read_text(encoding="utf-8")
marker = "(defun loop-typed-init"
start = source.index(marker)
end = source.index("\n\n(defun loop-optional-type", start)
form = source[start:end]
if sys.argv[2]:
    form = form.replace("(make-array dimensions :element-type element-type)",
                        "(coerce nil expanded-type)", 1)

required = [
    "((subtypep expanded-type 'vector)",
    "(sys.int::parse-array-type expanded-type)",
    "(integerp (first dimensions))",
    "(make-array dimensions :element-type element-type)",
    "(coerce nil expanded-type)",
]
missing = [token for token in required if token not in form]
if "TODO: Make this more complete." in form:
    missing.append("TODO marker removal")
if missing:
    raise SystemExit("LOOP typed-vector initializer contract missing: " + ", ".join(missing))
print("LOOP typed-vector initializer contract passed")
PY

if [[ -z "${ANSI_LOOP_TYPED_INIT_VECTOR_MUTATION_RUN:-}" ]]; then
  if ANSI_LOOP_TYPED_INIT_VECTOR_MUTATION_RUN=1 bash "$0" >/dev/null 2>&1; then
    echo "LOOP typed-vector initializer mutation unexpectedly survived" >&2
    exit 1
  fi
  echo "LOOP typed-vector initializer mutation rejected"
fi
