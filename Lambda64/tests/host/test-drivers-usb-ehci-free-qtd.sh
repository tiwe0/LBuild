#!/usr/bin/env bash
set -euo pipefail
script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "$script_dir/../.." && pwd)
source_file=${EHCI_SOURCE:-"$repo_root/drivers/usb/ehci-intel.lisp"}
python3 - "$source_file" "${EHCI_FREE_QTD_MUTATION_RUN:-}" <<'PY'
from pathlib import Path
import sys
source = Path(sys.argv[1]).read_text(encoding='utf-8')
start = source.index('(defun free-qh')
end = source.index('\n(defun qh-next-qh', start)
form = source[start:end]
if sys.argv[2]:
    form = form.replace('(free-qtd ehci qtd)', '(declare (ignore qtd))', 1)
required = ['(loop', '(ehci-addr->array ehci qtd-address)', '(free-qtd ehci qtd)',
            '(delete qtd (pending-qtds ehci))']
missing = [x for x in required if x not in form]
if 'TODO free any assocaited qtds' in form:
    missing.append('TODO marker removal')
if missing:
    raise SystemExit('EHCI free-QH qTD contract missing: ' + ', '.join(missing))
print('EHCI free-QH qTD contract passed')
PY
if [[ -z "${EHCI_FREE_QTD_MUTATION_RUN:-}" ]]; then
  if EHCI_FREE_QTD_MUTATION_RUN=1 bash "$0" >/dev/null 2>&1; then
    echo 'EHCI free-QH qTD mutation unexpectedly survived' >&2
    exit 1
  fi
  echo 'EHCI free-QH qTD mutation rejected'
fi
