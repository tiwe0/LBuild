#!/usr/bin/env bash
# Regression coverage for disjoint integer range intersections in the
# compiler type merger.
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "$script_dir/../.." && pwd)
source_file=${MERGE_INTEGER_TYPES_SOURCE:-"$repo_root/compiler/simplify.lisp"}

python3 - "$source_file" "${MERGE_INTEGER_TYPES_MUTATION_RUN:-}" <<'PY'
from pathlib import Path
import sys

source = Path(sys.argv[1]).read_text(encoding="utf-8")
required = [
    "(ranges-disjoint-p ()",
    "(if (ranges-disjoint-p)",
    "'(and (integer 0 1) (integer 3 4))",
    "'(and (integer 0 1) (integer (1) 4))",
]
if sys.argv[2]:
    source = source.replace("(if (ranges-disjoint-p)", "(if nil", 1)
missing = [token for token in required if token not in source]
if missing:
    raise SystemExit("disjoint integer-range contract missing: " + ", ".join(missing))
if sys.argv[2] and "(if nil" in source:
    raise SystemExit("disjoint integer-range mutation unexpectedly survived")
print("disjoint integer-range merge contract passed")
PY

if [[ -z "${MERGE_INTEGER_TYPES_MUTATION_RUN:-}" ]]; then
  if MERGE_INTEGER_TYPES_MUTATION_RUN=1 bash "$0" >/dev/null 2>&1; then
    echo "disjoint integer-range mutation unexpectedly survived" >&2
    exit 1
  fi
  echo "disjoint integer-range mutation rejected"
fi
