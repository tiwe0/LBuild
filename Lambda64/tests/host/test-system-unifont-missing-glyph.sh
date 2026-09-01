#!/usr/bin/env bash
set -euo pipefail
script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "$script_dir/../.." && pwd)
source_file=${UNIFONT_SOURCE:-"$repo_root/system/unifont.lisp"}
python3 - "$source_file" "${UNIFONT_MISSING_GLYPH_MUTATION_RUN:-}" <<'PY'
from pathlib import Path
import sys
source = Path(sys.argv[1]).read_text(encoding='utf-8')
if sys.argv[2]:
    source = source.replace('(make-array (list 16 8) :initial-element 0)', '(return-from map-unifont-2d nil)', 1)
required = [
    '(if glyph-offset',
    '(make-array (list 16 8) :initial-element 0)',
    '(setf (svref cache-row cell) glyph)',
]
missing = [x for x in required if x not in source]
if 'TODO: Generate missing characters here.' in source:
    missing.append('TODO marker removal')
if missing:
    raise SystemExit('Unifont missing-glyph contract missing: ' + ', '.join(missing))
print('Unifont missing-glyph contract passed')
PY
if [[ -z "${UNIFONT_MISSING_GLYPH_MUTATION_RUN:-}" ]]; then
  if UNIFONT_MISSING_GLYPH_MUTATION_RUN=1 bash "$0" >/dev/null 2>&1; then
    echo 'Unifont missing-glyph mutation unexpectedly survived' >&2
    exit 1
  fi
  echo 'Unifont missing-glyph mutation rejected'
fi
