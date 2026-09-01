#!/usr/bin/env bash
# Regression coverage for restart-case's signal/error/warn fast path.
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "$script_dir/../.." && pwd)
source_file=${RESTARTS_SOURCE:-"$repo_root/system/restarts.lisp"}

python3 - "$source_file" "${RESTARTS_FAST_PATH_MUTATION_RUN:-}" <<'PY'
from pathlib import Path
import sys

source = Path(sys.argv[1]).read_text(encoding="utf-8")
start = source.index("(defmacro restart-case")
end = source.index("\n\n(defmacro with-simple-restart", start)
form = source[start:end]
if sys.argv[2]:
    form = form.replace("(%restart-bind", "(restart-bind", 1)

required = [
    "(make-restart",
    "(%restart-bind",
    "(with-condition-restarts ,condition",
]
missing = [token for token in required if token not in form]
if "TODO: Do this without the calls to FIND-RESTART." in form:
    missing.append("TODO marker removal")
if "(find-restart" in form:
    missing.append("FIND-RESTART fast-path call removal")
if missing:
    raise SystemExit("restarts fast-path contract missing: " + ", ".join(missing))
print("restarts fast-path contract passed")
PY

if [[ -z "${RESTARTS_FAST_PATH_MUTATION_RUN:-}" ]]; then
  if RESTARTS_FAST_PATH_MUTATION_RUN=1 bash "$0" >/dev/null 2>&1; then
    echo "restarts fast-path mutation unexpectedly survived" >&2
    exit 1
  fi
  echo "restarts fast-path mutation rejected"
fi
