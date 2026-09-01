#!/usr/bin/env bash
set -euo pipefail
script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "$script_dir/../.." && pwd)
source_file=${COLD_CLOS_SOURCE:-"$repo_root/tools/cold-generator2/clos.lisp"}
python3 - "$source_file" "${COLD_CLOS_SLOT_MUTATION_RUN:-}" <<'PY'
from pathlib import Path
import sys
source = Path(sys.argv[1]).read_text(encoding="utf-8")
if sys.argv[2]:
    source = source.replace(":type type", ":type nil", 1)
required = [
    "(dolist (direct-slot (rest direct-slots))",
    "(assert (equal type",
    "(assert (eql allocation",
    ":type type",
    ":allocation allocation",
]
missing = [item for item in required if item not in source]
if missing:
    raise SystemExit("cold effective-slot consistency contract missing: " + ", ".join(missing))
print("cold effective-slot consistency contract passed")
PY
if [[ -z "${COLD_CLOS_SLOT_MUTATION_RUN:-}" ]]; then
  if COLD_CLOS_SLOT_MUTATION_RUN=1 bash "$0" >/dev/null 2>&1; then
    echo "cold effective-slot consistency mutation unexpectedly survived" >&2
    exit 1
  fi
  echo "cold effective-slot consistency mutation rejected"
fi
