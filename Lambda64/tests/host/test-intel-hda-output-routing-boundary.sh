#!/usr/bin/env bash
set -euo pipefail
repo_root=$(cd "$(dirname "$0")/../.." && pwd)
source="$repo_root/drivers/intel-hda.lisp"
python3 - "$source" <<'PY'
from pathlib import Path
import sys

text = Path(sys.argv[1]).read_text()
assert 'TODO: This should stream to anything' not in text
for token in ('Playback currently targets the single pin selected by DEFAULT-OUTPUT-PIN',
              'explicit fan-out policy',
              'SOUND-CARD-RUN intentionally keeps the one-pin contract',
              '(pin (default-output-pin hda))'):
    assert token in text, token
PY
printf 'Intel HDA output routing boundary checks passed\n'
