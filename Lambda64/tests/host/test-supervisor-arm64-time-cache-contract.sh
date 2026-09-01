#!/usr/bin/env bash
set -euo pipefail
repo_root=$(cd "$(dirname "$0")/../.." && pwd)
time="$repo_root/supervisor/arm64/time.lisp"
cache="$repo_root/supervisor/arm64/cache.lisp"
python3 - "$time" "$cache" <<'PY'
from pathlib import Path
import sys
time=Path(sys.argv[1]).read_text(); cache=Path(sys.argv[2]).read_text()
assert 'FIXME: need to deal with PPI vs SPI.' not in time
assert 'translate its FDT interrupt ID into the GIC global IRQ namespace' in time
assert 'FIXME: Assumed! This should actually be read from the config bits.' not in cache
assert 'architectural 64-byte minimum' in cache
# I-cache maintenance must use the aligned start, not the raw address.
section=cache[cache.index('(defun %arm64-sync-icache'):cache.index('(defun sys.int::dma-write-barrier')]
assert section.count('from start below end') == 2
PY
printf 'arm64 time/cache contract checks passed\n'
