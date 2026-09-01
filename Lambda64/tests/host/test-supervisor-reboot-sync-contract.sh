#!/usr/bin/env bash
set -euo pipefail
repo_root=$(cd "$(dirname "$0")/../.." && pwd)
source="$repo_root/supervisor/entry.lisp"
python3 - "$source" <<'PY'
from pathlib import Path
import sys
text=Path(sys.argv[1]).read_text()
assert 'FIXME: Need to sync disks and wait until snapshotting finishes.' not in text
body=text[text.index('(defun reboot'):text.index(';;; <<<<<<')]
for token in ('(dolist (disk (all-disks))', '(disk-valid disk)', '(disk-flush disk)',
              '*snapshot-in-progress*', '(wait-for-snapshot-completion)',
              '(platform-reboot)'):
    assert token in body, token
assert body.index('(disk-flush disk)') < body.index('(platform-reboot)')
assert body.index('(wait-for-snapshot-completion)') < body.index('(platform-reboot)')
PY
printf 'reboot sync contract checks passed\n'
