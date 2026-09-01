#!/usr/bin/env bash
# Contract: thread cleanup transitions to :dead under the global lock, then
# publishes the join event after releasing it.  This prevents joiners from
# observing a live thread and avoids event-state lock inversion on SMP.
set -euo pipefail
root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
python3 - "$root/supervisor/thread.lisp" <<'PY'
from pathlib import Path
import sys
s = Path(sys.argv[1]).read_text()
start = s.index('(defun thread-final-cleanup')
end = s.index('(defun thread-join', start)
body = s[start:end]
lock = body.index('(acquire-global-thread-lock)')
dead = body.index('(setf (thread-state self) :dead)')
unlock = body.index('(release-global-thread-lock)', dead)
event = body.index('(setf (event-state (thread-join-event self))', unlock)
relock = body.index('(acquire-global-thread-lock)', event)
assert lock < dead < unlock < event < relock
assert 'FIXME' not in body
print('thread cleanup lock-order contract passed')
PY
