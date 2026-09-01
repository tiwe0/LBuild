#!/usr/bin/env bash
set -euo pipefail
script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "$script_dir/../.." && pwd)
source_file=${COLD_STRUCTURE_SOURCE:-"$repo_root/tools/cold-generator2/environment.lisp"}
python3 - "$source_file" "${COLD_STRUCTURE_INHERITANCE_MUTATION_RUN:-}" <<'PY'
from pathlib import Path
import sys

source = Path(sys.argv[1]).read_text(encoding="utf-8")
if sys.argv[2]:
    source = source.replace(":direct-superclasses (list (or parent-class (find-class 'instance-object)))",
                            ":direct-superclasses (list (find-class 'instance-object'))", 1)

required = [
    "(structure-definition-parent sdef)",
    ":direct-superclasses (list (or parent-class (find-class 'instance-object)))",
    "(remove-if (lambda (slot)",
    "parent-slots",
]
missing = [item for item in required if item not in source]
if missing:
    raise SystemExit("cold structure inheritance contract missing: " + ", ".join(missing))
print("cold structure inheritance contract passed")
PY

if [[ -z "${COLD_STRUCTURE_INHERITANCE_MUTATION_RUN:-}" ]]; then
  if COLD_STRUCTURE_INHERITANCE_MUTATION_RUN=1 bash "$0" >/dev/null 2>&1; then
    echo "cold structure inheritance mutation unexpectedly survived" >&2
    exit 1
  fi
  echo "cold structure inheritance mutation rejected"
fi
