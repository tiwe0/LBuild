#!/usr/bin/env bash
set -euo pipefail
script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "$script_dir/../.." && pwd)
source_file=${COLD_SERIALIZE_SOURCE:-"$repo_root/tools/cold-generator2/serialize.lisp"}
python3 - "$source_file" "${COLD_SERIALIZE_WIDE_MUTATION_RUN:-}" <<'PY'
from pathlib import Path
import sys
source = Path(sys.argv[1]).read_text(encoding='utf-8')
if sys.argv[2]:
    source = source.replace('(t 32)))', '(t 8)))', 1)
required = [
    'sys.int::+object-tag-array-unsigned-byte-16+',
    'sys.int::+object-tag-array-unsigned-byte-32+',
    '(char-code (char object',
    '(* (length object) element-size)',
    '(t 32)))',
]
missing = [x for x in required if x not in source]
if 'TODO: Support strings with characters outside the latin-1 range.' in source:
    missing.append('TODO marker removal')
if missing:
    raise SystemExit('wide-string serialization contract missing: ' + ', '.join(missing))
print('wide-string serialization contract passed')
PY
if [[ -z "${COLD_SERIALIZE_WIDE_MUTATION_RUN:-}" ]]; then
  if COLD_SERIALIZE_WIDE_MUTATION_RUN=1 bash "$0" >/dev/null 2>&1; then
    echo 'wide-string serialization mutation unexpectedly survived' >&2
    exit 1
  fi
  echo 'wide-string serialization mutation rejected'
fi
