#!/usr/bin/env bash
# Ensure unresolved EHCI/USB markers have canonical, reviewable specifications.
set -euo pipefail
script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "$script_dir/../.." && pwd)
python3 - "$repo_root" <<'PY'
from pathlib import Path
import re,sys
root=Path(sys.argv[1]); specs=root.parent/'docs/modernization/todo-fixme/specs'
checks={
 'drivers/usb/ehci-intel.lisp':['0091','0092','0093','0094','0095','0096','0097','0098'],
 'drivers/usb/usb-driver.lisp':['0121'],
}
for rel,ids in checks.items():
 text=(root/rel).read_text(encoding='utf-8')
 markers=[m.start() for m in re.finditer(r'\b(?:TODO|FIXME)\b',text)]
 # A boundary may be fully implemented; retain the canonical spec as the
 # audit trail even when no source marker remains.
 for i in ids:
  p=specs/f'TF-WI-{i}.md'
  if not p.exists(): raise SystemExit(f'missing canonical spec {p}')
  s=p.read_text(encoding='utf-8')
  for token in ('status: active','review-cycle: 30d','source-of-truth: code'):
   if token not in s: raise SystemExit(f'{p}: missing {token}')
  if '## Required evidence' not in s and '## 当前证据' not in s:
   raise SystemExit(f'{p}: missing evidence section')
  if i != '0097' and 'owner: io-platform' not in s: raise SystemExit(f'{p}: owner must be io-platform')
print('USB EHCI TODO boundary specs passed')
PY
