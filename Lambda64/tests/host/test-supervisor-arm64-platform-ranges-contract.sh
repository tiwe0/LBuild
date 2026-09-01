#!/usr/bin/env bash
set -euo pipefail
repo_root=$(cd "$(dirname "$0")/../.." && pwd)
source="$repo_root/supervisor/arm64/platform.lisp"
python3 - "$source" <<'PY'
from pathlib import Path
import sys
text=Path(sys.argv[1]).read_text()
assert ';; TODO.' not in text
start=text.index(';; Non-empty ranges require translating')
body=text[start:start+420]
for token in ('translation context/API', 'ignoring such buses', 'untranslated address'):
    assert token in body, token
PY
printf 'arm64 platform ranges contract checks passed\n'
