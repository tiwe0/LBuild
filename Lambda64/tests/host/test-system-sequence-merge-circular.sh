#!/usr/bin/env bash
# Regression coverage for rejecting circular lists before MERGE can loop.
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "$script_dir/../.." && pwd)
source_file=${SEQUENCE_SOURCE:-"$repo_root/system/sequence.lisp"}

python3 - "$source_file" "${SEQUENCE_MERGE_CIRCULAR_MUTATION_RUN:-}" <<'PY'
from pathlib import Path
import sys

source = Path(sys.argv[1]).read_text(encoding="utf-8")
marker = "(defun merge (result-type sequence1 sequence2 predicate"
start = source.index(marker)
end = source.index("\n\n(defun map-into", start)
form = source[start:end]
if sys.argv[2]:
    form = form.replace("(null (list-length sequence))", "nil", 1)

required = [
    "(and (consp sequence)",
    "(null (list-length sequence))",
    "MERGE does not accept circular lists",
]
missing = [token for token in required if token not in form]
if "FIXME: This will break on circular lists" in form:
    missing.append("FIXME marker removal")
if missing:
    raise SystemExit("MERGE circular-list contract missing: " + ", ".join(missing))
print("MERGE circular-list contract passed")
PY

if [[ -z "${SEQUENCE_MERGE_CIRCULAR_MUTATION_RUN:-}" ]]; then
  if SEQUENCE_MERGE_CIRCULAR_MUTATION_RUN=1 bash "$0" >/dev/null 2>&1; then
    echo "MERGE circular-list mutation unexpectedly survived" >&2
    exit 1
  fi
  echo "MERGE circular-list mutation rejected"
fi
