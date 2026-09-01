#!/usr/bin/env bash
# Host contract for the explicit VALUES &ALLOW-OTHER-KEYS policy boundary.
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "$script_dir/../.." && pwd)
source_file=${TYPE_CHECK_SOURCE:-"$repo_root/compiler/type-check.lisp"}

python3 - "$source_file" "${TYPE_CHECK_ALLOW_OTHER_KEYS_MUTATION_RUN:-}" <<'PY'
from pathlib import Path
import sys

source = Path(sys.argv[1]).read_text(encoding="utf-8")
required = [
    "allow-other-keys)",
    "(declare (ignore allow-other-keys))",
    "&ALLOW-OTHER-KEYS is a function-type lambda-list marker",
    "bearing on value-count or value-type checking",
]
if sys.argv[2]:
    source = source.replace("(declare (ignore allow-other-keys))", "(declare (ignore required-typespecs))", 1)
missing = [token for token in required if token not in source]
if missing:
    raise SystemExit("type-check &ALLOW-OTHER-KEYS contract missing: " + ", ".join(missing))
print("type-check &ALLOW-OTHER-KEYS contract passed (mutation-aware)")
PY

if [[ -z "${TYPE_CHECK_ALLOW_OTHER_KEYS_MUTATION_RUN:-}" ]]; then
  if TYPE_CHECK_ALLOW_OTHER_KEYS_MUTATION_RUN=1 bash "$0" >/dev/null 2>&1; then
    echo "type-check &ALLOW-OTHER-KEYS mutation unexpectedly survived" >&2
    exit 1
  fi
  echo "type-check &ALLOW-OTHER-KEYS mutation rejected"
fi
