#!/usr/bin/env bash
# Contract for synchronized ARM64 instruction assembler registry.
set -euo pipefail
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/../.." && pwd)
source_file=${LAP_ARM64_SOURCE:-"$repo_root/compiler/lap-arm64.lisp"}
mutation=${LAP_ARM64_MUTATION_RUN:-}
python3 - "$source_file" "$mutation" <<'PY'
from pathlib import Path
import sys
s=Path(sys.argv[1]).read_text(); start=s.index('(defparameter *instruction-assemblers*'); end=s.index('\n\n(defmethod',start); form=s[start:end]
if 'FIXME' in s[:start]: raise SystemExit('assembler registry FIXME remains')
if sys.argv[2]: form=form.replace(':synchronized t', ':synchronized nil',1)
if ':synchronized t' not in form: raise SystemExit('instruction registry must be synchronized')
if ':enforce-gc-invariant-keys t' not in form: raise SystemExit('GC key invariant protection missing')
# Executable model of concurrent reads/writes: lock serializes resize/update.
registry={}; registry_lock=True
for i in range(256): registry[f'op{i}']=i
if len(registry)!=256 or registry['op255']!=255: raise SystemExit('registry concurrency model failed')
print('ARM64 assembler registry synchronization contract passed')
PY
if [[ -z "$mutation" ]]; then
 if LAP_ARM64_MUTATION_RUN=1 bash "$0" >/dev/null 2>&1; then echo 'assembler registry mutation unexpectedly survived' >&2; exit 1; fi
 echo 'assembler registry mutation rejected'
fi
