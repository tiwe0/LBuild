#!/usr/bin/env bash
set -euo pipefail
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/../.." && pwd)
source_file=${AHCI_SOURCE:-"$repo_root/supervisor/ahci.lisp"}
python3 - "$source_file" <<'PY'
from pathlib import Path
import re,sys
s=Path(sys.argv[1]).read_text()
def need(p,m):
 if not re.search(p,s,re.S): raise SystemExit(m)
if re.search(r'(?im)^\s*;+.*\b(?:TODO|FIXME)\b',s): raise SystemExit('AHCI TODO/FIXME markers remain')
need(r'\+ahci-comreset-minimum-seconds\+.*safe-sleep \+ahci-comreset-minimum-seconds\+', 'COMRESET minimum assertion missing')
need(r'defun ahci-call-with-dma-buffer.*:32-bit-only t.*unwind-protect.*release-physical-pages', 'DMA32 bounce lifecycle missing')
need(r'defun ahci-setup-no-data.*PRDTL', 'no-data command header setup missing')
need(r'defun ahci-flush.*ahci-setup-no-data.*flush-cache-ext', 'flush command not issued')
need(r'defun ahci-maximum-transfer-sectors.*#x10000', 'LBA48 maximum transfer not advertised')
need(r'defun ahci-validate-lba-transfer.*sector-count', 'device and ATA range validation missing')
need(r'defun ahci-run-command.*ahci-port-reset.*return-from ahci-run-command nil', 'command timeout does not fail and reset')
need(r'defun ahci-port-reset \(ahci port &key \(restart t\)\)', 'port reset cannot leave engines stopped')
need(r'defun ahci-initialize-port.*ahci-port-reset ahci port :restart nil', 'initialization reset restarts the command engine')
need(r'running-mask.*ahci-PxCMD-ST.*ahci-PxCMD-FRE.*ahci-PxCMD-CR.*ahci-PxCMD-FR', 'initialization does not verify all engine bits are clear')
print('AHCI source contracts passed')
PY
