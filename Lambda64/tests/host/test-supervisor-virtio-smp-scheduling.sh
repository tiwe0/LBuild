#!/usr/bin/env bash
# Contract test for Virtio supervisor scheduling on ARM64 SMP.
set -euo pipefail
root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
python3 - "$root" <<'PY'
from pathlib import Path
import sys
root=Path(sys.argv[1])
thread=(root/'supervisor/thread.lisp').read_text()
virtio=(root/'supervisor/virtio.lisp').read_text()
arm=(root/'supervisor/arm64/cache.lisp').read_text()
x86=(root/'supervisor/x86-64/cpu.lisp').read_text()
assert 'FIXME, HACK! Virtio drivers seem to be broken' not in thread
assert '#+arm64 (eql (local-cpu-info) *bsp-cpu*)' not in thread
# Both normal and world-stop paths consume supervisor work without PE affinity.
assert thread.count('(pop-run-queue-1 *supervisor-priority-run-queue*)') >= 2
# Device-produced used-ring entries are ordered before consumption on every ISA.
assert '(sys.int::dma-read-barrier)' in virtio
assert '(defun sys.int::dma-read-barrier' in arm
assert '(defun sys.int::dma-read-barrier' in x86
print('Virtio supervisor SMP scheduling and DMA read ordering passed')
PY
