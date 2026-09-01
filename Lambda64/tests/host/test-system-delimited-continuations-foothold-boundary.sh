#!/usr/bin/env bash
set -euo pipefail
repo_root=$(cd "$(dirname "$0")/../.." && pwd)
source="$repo_root/system/delimited-continuations-x86-64.lisp"
python3 - "$source" <<'PY'
from pathlib import Path
import sys
s = Path(sys.argv[1]).read_text()
assert 'FIXME: Need to run pending footholds' not in s
assert s.count('Pending footholds are intentionally deferred') == 2
assert 'normal supervisor safepoints run the queue once values are preserved' in s
assert 'The resume path must return with its multiple-value register protocol' in s
# Both paths still explicitly invoke the queue before entering user code.
assert s.count('(:call (:named-call mezzano.supervisor::run-pending-footholds))') == 0
assert s.count('(:named-call mezzano.supervisor::run-pending-footholds)') >= 2
PY
printf 'delimited-continuations foothold boundary checks passed\n'
