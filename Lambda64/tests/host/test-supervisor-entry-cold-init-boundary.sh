#!/usr/bin/env bash
set -euo pipefail
repo_root=$(cd "$(dirname "$0")/../.." && pwd)
source="$repo_root/supervisor/entry.lisp"
thread_source="$repo_root/supervisor/thread.lisp"
python3 - "$source" "$thread_source" <<'PY'
from pathlib import Path
import sys

text = Path(sys.argv[1]).read_text()
thread_text = Path(sys.argv[2]).read_text()
assert 'FIXME: Should be done by cold generator' not in text
for token in ('intentionally reset at first supervisor boot',
              'current cold generator does not emit',
              'generated-image ABI',
              "mezzano.runtime::*active-catch-handlers*",
              "sys.int::*known-finalizers*"):
    assert token in text, token

queues = text.index('(%make-wait-queue \'*pending-world-stoppers*)')
first_irq_enable = text.index('(%enable-interrupts)')
assert queues < first_irq_enable, 'pending queues must be published before early IRQ enable'
assert "(thread-wait-item sys.int::*pager-thread*) '*pager-waiting-threads*" in thread_text, \
    'cold pager must use the wake-up queue token'
PY
printf 'supervisor entry cold-init boundary checks passed\n'
