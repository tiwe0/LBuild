#!/usr/bin/env bash
set -euo pipefail
repo_root=$(cd "$(dirname "$0")/../.." && pwd)
source="$repo_root/supervisor/virtio-mmio.lisp"
python3 - "$source" <<'PY'
from pathlib import Path
import sys
text=Path(sys.argv[1]).read_text()
assert 'FIXME: IRQ routing.' not in text
start=text.index('(defun sup::virtio-mmio-fdt-register')
body=text[start:text.index('(defun virtio-legacy-mmio-transport-kick', start)]
for token in ('fdt-read-u32 interrupts 0', 'fdt-read-u32 interrupts 1',
              '(0 32)', '(1 16)', 'unsupported FDT IRQ type'):
    assert token in body, token
# GIC global IRQ conversion contract: SPI IDs start at 32, PPI IDs at 16.
def global_irq(kind, ident):
    return (32 if kind == 0 else 16) + ident
assert global_irq(0, 48) == 80
assert global_irq(1, 27) == 43
PY
printf 'virtio-mmio IRQ routing checks passed\n'
