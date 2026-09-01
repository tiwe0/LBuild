#!/usr/bin/env bash
# Host contract for atomic supersede-instance publication.
set -euo pipefail
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/../.." && pwd)
source_file=${INSTANCE_SOURCE:-"$repo_root/runtime/instance.lisp"}
mutation=${INSTANCE_MUTATION_RUN:-}
python3 - "$source_file" "$mutation" <<'PY'
from pathlib import Path
import sys
s=Path(sys.argv[1]).read_text()
start=s.index('(defun supersede-instance')
end=s.index('\n(in-package :mezzano.internals)', start)
form=s[start:end]
if sys.argv[2]:
    form=form.replace('(sys.int::cas\n                       (sys.int::%object-ref-unsigned-byte-64 old-instance -1)', '(setf (sys.int::%object-ref-unsigned-byte-64 old-instance -1)', 1)
if 'TODO' in form or 'FIXME' in form:
    raise SystemExit('supersede-instance retains TODO/FIXME')
for anchor in (
    '(loop',
    '(sys.int::cas\n                       (sys.int::%object-ref-unsigned-byte-64 old-instance -1)',
    '(sys.int::cas (sys.int::layout-new-instance layout)',
    '(with-live-objects (new-layout)',
):
    if anchor not in form:
        raise SystemExit(f'missing atomic publication anchor: {anchor}')
if form.index('(with-live-objects (new-layout)') > form.index('(sys.int::cas\n                       (sys.int::%object-ref-unsigned-byte-64 old-instance -1)'):
    raise SystemExit('new layout must be rooted before header CAS')
print('instance supersede atomic publication contract passed')
PY
if [[ -z "$mutation" ]]; then
  if INSTANCE_MUTATION_RUN=1 bash "$0" >/dev/null 2>&1; then
    echo 'instance supersede mutation unexpectedly survived' >&2
    exit 1
  fi
  echo 'instance supersede mutation rejected'
fi
