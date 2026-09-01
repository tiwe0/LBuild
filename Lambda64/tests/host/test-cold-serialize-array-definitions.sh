#!/usr/bin/env bash
set -euo pipefail
script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "$script_dir/../.." && pwd)
source_file=${COLD_SERIALIZE_SOURCE:-"$repo_root/tools/cold-generator2/serialize.lisp"}
python3 - "$source_file" <<'PY'
from pathlib import Path
import sys
source = Path(sys.argv[1]).read_text(encoding='utf-8')
required = [
    'find element-type sys.int::*array-info*',
    'specialized-array-definition-element-size',
    'specialized-array-definition-tag',
    'Unsupported array element-type',
]
missing = [x for x in required if x not in source]
if missing:
    raise SystemExit('cold serializer array definition lookup missing: ' + ', '.join(missing))
if 'FIXME: Need to take these from the specialized array definitions.' in source:
    raise SystemExit('stale duplicated array definition FIXME remains')
print('cold serializer array definition lookup contract passed')
PY
