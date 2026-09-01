#!/usr/bin/env bash
# Regression coverage for exported binary/generic logical arithmetic entry points.
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "$script_dir/../.." && pwd)
source_file=${LOGICAL_SOURCE:-"$repo_root/system/numbers/logical.lisp"}

python3 - "$source_file" "${LOGICAL_EXPORTS_MUTATION_RUN:-}" <<'PY'
from pathlib import Path
import sys
source = Path(sys.argv[1]).read_text(encoding='utf-8')
marker = '(eval-when (:compile-toplevel :load-toplevel :execute)\n  (import '
start = source.index(marker)
end = source.index('\n\n(macrolet', start)
form = source[start:end]
if sys.argv[2]:
    form = form.replace('binary-logand generic-logand', 'binary-logand', 1)
required = [
    'int::binary-logand', 'int::generic-logand',
    'int::binary-logior', 'int::generic-logior',
    'int::binary-logxor', 'int::generic-logxor',
    '(export', 'binary-logand generic-logand',
    'binary-logior generic-logior', 'binary-logxor generic-logxor',
]
missing = [token for token in required if token not in form]
if missing:
    raise SystemExit('logical arithmetic export contract missing: ' + ', '.join(missing))
print('logical binary/generic export contract passed')
PY

if [[ -z "${LOGICAL_EXPORTS_MUTATION_RUN:-}" ]]; then
  if LOGICAL_EXPORTS_MUTATION_RUN=1 bash "$0" >/dev/null 2>&1; then
    echo "logical arithmetic export mutation unexpectedly survived" >&2
    exit 1
  fi
  echo "logical arithmetic export mutation rejected"
fi
