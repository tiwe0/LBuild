#!/usr/bin/env bash
set -euo pipefail
script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "$script_dir/../.." && pwd)
source_file=${COLD_SERIALIZE_SOURCE:-"$repo_root/tools/cold-generator2/serialize.lisp"}
python3 - "$source_file" "${COLD_SERIALIZE_UNBOXED_MUTATION_RUN:-}" <<'PY'
from pathlib import Path
import sys
source = Path(sys.argv[1]).read_text(encoding='utf-8')
if sys.argv[2]:
    source = source.replace('(ldb (byte loc-element-bit-size 0) raw-value)',
                            '(ldb (byte 0 loc-element-bit-size) raw-value)', 1)
required = [
    'sys.int::%single-float-as-integer slot-value',
    'sys.int::%double-float-as-integer slot-value',
    '(truncate (+ loc-offset (* index loc-element-size)) 8)',
    '(byte loc-element-bit-size (* slot-offset 8))',
    '(ldb (byte loc-element-bit-size 0) raw-value)',
]
missing = [x for x in required if x not in source]
if missing:
    raise SystemExit('cold serializer unboxed-slot contract missing: ' + ', '.join(missing))
if 'TODO: Implement single-/double-float locations' in source:
    raise SystemExit('cold serializer float-location TODO marker remains')
print('cold serializer unboxed-slot contract passed')
PY
if [[ -z "${COLD_SERIALIZE_UNBOXED_MUTATION_RUN:-}" ]]; then
  if COLD_SERIALIZE_UNBOXED_MUTATION_RUN=1 bash "$0" >/dev/null 2>&1; then
    echo 'cold serializer unboxed-slot mutation unexpectedly survived' >&2
    exit 1
  fi
  echo 'cold serializer unboxed-slot mutation rejected'
fi
