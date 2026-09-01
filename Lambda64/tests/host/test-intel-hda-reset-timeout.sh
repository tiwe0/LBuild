#!/usr/bin/env bash
set -euo pipefail
repo_root=$(cd "$(dirname "$0")/../.." && pwd)
source="$repo_root/drivers/intel-hda.lisp"
grep -q '(defconstant +controller-reset-poll-limit+ 10000)' "$source"
python3 - "$source" <<'PY'
from pathlib import Path
import sys
text=Path(sys.argv[1]).read_text()
assert 'FIXME: Timeouts' not in text
assert text.count('repeat +controller-reset-poll-limit+') >= 2
assert 'Intel HDA controller did not leave reset.' in text
assert 'Intel HDA controller did not enter reset-complete state.' in text
PY
printf 'intel-hda reset timeout checks passed\n'
