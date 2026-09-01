#!/usr/bin/env bash
set -euo pipefail
repo_root=$(cd "$(dirname "$0")/../.." && pwd)
source="$repo_root/supervisor/entry.lisp"
python3 - "$source" <<'PY'
from pathlib import Path
import sys

text = Path(sys.argv[1]).read_text()
assert 'FIXME: Should be done by cold generator' not in text
for token in ('intentionally reset at first supervisor boot',
              'current cold generator does not emit',
              'generated-image ABI',
              "mezzano.runtime::*active-catch-handlers*",
              "sys.int::*known-finalizers*"):
    assert token in text, token

queues = text.index('(make-wait-queue :name \'*pending-world-stoppers*)')
first_irq_enable = text.index('(%enable-interrupts)')
assert queues < first_irq_enable, 'pending queues must be published before early IRQ enable'
PY
printf 'supervisor entry cold-init boundary checks passed\n'
