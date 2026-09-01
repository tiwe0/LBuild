#!/usr/bin/env bash
set -euo pipefail
script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "$script_dir/../.." && pwd)
source_file=${CLOS_STRUCT_SOURCE:-"$repo_root/system/clos/struct.lisp"}
python3 - "$source_file" "${CLOS_STRUCT_PARENT_MUTATION_RUN:-}" <<'PY'
from pathlib import Path
import sys
source = Path(sys.argv[1]).read_text(encoding='utf-8')
if sys.argv[2]:
    source = source.replace("(safe-remove-direct-subclass old-parent existing-class)", "nil", 1)
required = [
    "(old-parent (first (class-direct-superclasses existing-class)))",
    "(new-parent (or (and parent-definition (%defstruct parent-definition))",
    "(safe-remove-direct-subclass old-parent existing-class)",
    "(safe-add-direct-subclass new-parent existing-class)",
]
missing = [x for x in required if x not in source]
if "FIXME: If the parent class changes" in source:
    missing.append("FIXME marker removal")
if missing:
    raise SystemExit("structure parent redefinition contract missing: " + ", ".join(missing))
print("structure parent redefinition contract passed")
PY
if [[ -z "${CLOS_STRUCT_PARENT_MUTATION_RUN:-}" ]]; then
  if CLOS_STRUCT_PARENT_MUTATION_RUN=1 bash "$0" >/dev/null 2>&1; then
    echo "structure parent redefinition mutation unexpectedly survived" >&2
    exit 1
  fi
  echo "structure parent redefinition mutation rejected"
fi
