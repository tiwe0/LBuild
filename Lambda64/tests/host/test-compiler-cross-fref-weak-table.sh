#!/usr/bin/env bash
set -euo pipefail
script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "$script_dir/../.." && pwd)
source_file=${CROSS_COMPILE_SOURCE:-"$repo_root/compiler/cross-compile.lisp"}
python3 - "$source_file" "${CROSS_FREF_WEAK_MUTATION_RUN:-}" <<'PY'
from pathlib import Path
import sys
s=Path(sys.argv[1]).read_text()
if sys.argv[2]: s=s.replace(":weakness :value", "", 1)
required=["(make-hash-table :test #'equal :weakness :value)", "SETF/CAS names"]
missing=[x for x in required if x not in s]
if "FIXME: Should be a weak hash table" in s: missing.append("FIXME marker removal")
if missing: raise SystemExit("cross fref weak-table contract missing: "+", ".join(missing))
print("cross function-reference weak-table contract passed")
PY
if [[ -z "${CROSS_FREF_WEAK_MUTATION_RUN:-}" ]]; then
  if CROSS_FREF_WEAK_MUTATION_RUN=1 bash "$0" >/dev/null 2>&1; then
    echo "cross fref weak-table mutation unexpectedly survived" >&2; exit 1
  fi
  echo "cross fref weak-table mutation rejected"
fi
