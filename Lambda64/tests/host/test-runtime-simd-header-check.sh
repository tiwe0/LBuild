#!/usr/bin/env bash
# Contract for SIMD pack type checks: tag guard precedes header decoding.
set -euo pipefail
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/../.." && pwd)
source_file=${SIMD_SOURCE:-"$repo_root/runtime/simd.lisp"}
mutation=${SIMD_MUTATION_RUN:-}
python3 - "$source_file" "$mutation" <<'PY'
from pathlib import Path
import sys
s=Path(sys.argv[1]).read_text(); start=s.index('(defun compile-simd-pack-type'); end=s.index('\n  (int::%define-type-symbol',start); form=s[start:end]
if 'TODO' in form or 'FIXME' in form: raise SystemExit('SIMD header TODO/FIXME remains')
if sys.argv[2]: form=form.replace('(simd-pack-p ,object)', '(eql ,object t)', 1)
if form.count('(simd-pack-p ,object)') < 4: raise SystemExit('all SIMD type branches need tag guard')
if 'wildcard branches mask selected header fields' not in form: raise SystemExit('SIMD header rationale missing')
print('SIMD header type-check contract passed')
PY
if [[ -z "$mutation" ]]; then
 if SIMD_MUTATION_RUN=1 bash "$0" >/dev/null 2>&1; then echo 'SIMD mutation unexpectedly survived' >&2; exit 1; fi
 echo 'SIMD mutation rejected'
fi
