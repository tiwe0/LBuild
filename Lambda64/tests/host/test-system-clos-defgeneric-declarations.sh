#!/usr/bin/env bash
set -euo pipefail
script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "$script_dir/../.." && pwd)
source_file=${CLOS_MACROS_SOURCE:-"$repo_root/system/clos/macros.lisp"}
python3 - "$source_file" "${CLOS_DECLARATIONS_MUTATION_RUN:-}" <<'PY'
from pathlib import Path
import sys
source = Path(sys.argv[1]).read_text(encoding='utf-8')
if sys.argv[2]:
    source = source.replace("append (rest option)", "append nil", 1)
required = [
    "(declarations (loop",
    "append (rest option)",
    "unless (eql (first opt) 'declare)",
    "(:declarations ',declarations)",
]
missing = [x for x in required if x not in source]
if "FIXME: Declarations must be accumulated." in source:
    missing.append("FIXME marker removal")
if missing:
    raise SystemExit("DEFGENERIC declaration accumulation contract missing: " + ", ".join(missing))
print("DEFGENERIC declaration accumulation contract passed")
PY
if [[ -z "${CLOS_DECLARATIONS_MUTATION_RUN:-}" ]]; then
  if CLOS_DECLARATIONS_MUTATION_RUN=1 bash "$0" >/dev/null 2>&1; then
    echo "DEFGENERIC declaration mutation unexpectedly survived" >&2
    exit 1
  fi
  echo "DEFGENERIC declaration mutation rejected"
fi
