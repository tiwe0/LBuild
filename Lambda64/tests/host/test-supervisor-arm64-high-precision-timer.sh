#!/usr/bin/env bash
# Regression coverage for the ARM64 high-precision timer contract.
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "$script_dir/../.." && pwd)
source_file=${ARM64_TIME_SOURCE:-"$repo_root/supervisor/arm64/time.lisp"}

python3 - "$source_file" "${ARM64_TIMER_MUTATION_RUN:-}" <<'PY'
from pathlib import Path
import re
import sys

source = Path(sys.argv[1]).read_text(encoding="utf-8")
start = source.index("(defun get-high-precision-timer")
end = source.index("\n\n(defun high-precision-time-units-to-internal-time-units", start)
form = source[start:end]
if sys.argv[2]:
    form = re.sub(r'\n\s*"Returns the current value.*?UNITS\."', '', form, count=1, flags=re.S)

required = [
    '"Returns the current value of the platform\'s \'high precision\' timer.',
    '(%cntvct-el0)',
    '(%isb)',
]
missing = [token for token in required if token not in form]
if re.search(r'\bTODO\b|\bFIXME\b', form):
    missing.append("TODO/FIXME marker removal")
if missing:
    raise SystemExit("ARM64 high-precision timer contract missing: " + ", ".join(missing))
print("ARM64 high-precision timer contract passed")
PY

if [[ -z "${ARM64_TIMER_MUTATION_RUN:-}" ]]; then
  if ARM64_TIMER_MUTATION_RUN=1 bash "$0" >/dev/null 2>&1; then
    echo "ARM64 high-precision timer mutation unexpectedly survived" >&2
    exit 1
  fi
  echo "ARM64 high-precision timer mutation rejected"
fi
