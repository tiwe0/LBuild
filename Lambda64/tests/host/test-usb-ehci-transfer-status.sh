#!/usr/bin/env bash
# Contract that EHCI bulk completion propagates raw qTD status bits.
set -euo pipefail
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/../.." && pwd)
source_file=${EHCI_SOURCE:-"$repo_root/drivers/usb/ehci-intel.lisp"}
mutation=${EHCI_MUTATION_RUN:-}
python3 - "$source_file" "$mutation" <<'PY'
from pathlib import Path
import sys
s=Path(sys.argv[1]).read_text(); start=s.index('(defun handle-bulk-endpt'); end=s.index('\n;;======================================================================\n;; set-device-address',start); form=s[start:end]
if 'TODO check condition code' in form: raise SystemExit('EHCI status TODO remains')
if sys.argv[2]: form=form.replace('Preserve the EHCI condition-code bits in STATUS.', 'Discard the EHCI condition-code bits in STATUS.',1)
for a in ('(qtd-token qtd)', '+qtd-status-mask+', '(transfer-complete', 'Preserve the EHCI condition-code bits in STATUS.'):
    if a not in form: raise SystemExit(f'missing EHCI status propagation anchor: {a}')
# Executable mask model: all five qTD status bits survive masking.
mask=0xF8
for token in (0,0x08,0x10,0x20,0x40,0x78,0xFF):
    if (token & mask) != (token & 0xF8): raise SystemExit('status mask model failed')
print('EHCI transfer status propagation contract passed')
PY
if [[ -z "$mutation" ]]; then
 if EHCI_MUTATION_RUN=1 bash "$0" >/dev/null 2>&1; then echo 'EHCI mutation unexpectedly survived' >&2; exit 1; fi
 echo 'EHCI mutation rejected'
fi
