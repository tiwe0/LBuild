#!/usr/bin/env bash
set -euo pipefail
script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "$script_dir/../.." && pwd)
source_file=${COLD_SERIALIZE_SOURCE:-"$repo_root/tools/cold-generator2/serialize.lisp"}
python3 - "$source_file" "${COLD_SERIALIZE_RANK_MUTATION_RUN:-}" <<'PY'
from pathlib import Path
import sys
source = Path(sys.argv[1]).read_text(encoding='utf-8')
if sys.argv[2]:
    source = source.replace('(unless (eql (array-rank object) 1)', '(when nil', 1)
required = [
    '(defmethod allocate-object ((object array) image environment)',
    '(unless (eql (array-rank object) 1)',
    '(error "Cold serializer only supports rank-1 arrays, got rank ~D."',
]
missing = [x for x in required if x not in source]
if '(assert (eql (array-rank object) 1)) ; TODO' in source:
    missing.append('TODO marker removal')
if missing:
    raise SystemExit('cold serializer array-rank contract missing: ' + ', '.join(missing))
print('cold serializer array-rank contract passed')
PY
if [[ -z "${COLD_SERIALIZE_RANK_MUTATION_RUN:-}" ]]; then
  if COLD_SERIALIZE_RANK_MUTATION_RUN=1 bash "$0" >/dev/null 2>&1; then
    echo 'cold serializer array-rank mutation unexpectedly survived' >&2
    exit 1
  fi
  echo 'cold serializer array-rank mutation rejected'
fi
